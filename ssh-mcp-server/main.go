package sshmcpserver
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/security/keyvault/azsecrets"
	"golang.org/x/crypto/ssh"
)

// hostMap maps aliases (vm1, vm2, vm3, bench) to private IPs.
var hostMap map[string]string

// sshUser is the SSH username.
var sshUser string

// sshSigner is the parsed SSH private key.
var sshSigner ssh.Signer

// sshSignerOnce ensures the key is loaded once.
var sshSignerOnce sync.Once

func main() {
	hostMapJSON := os.Getenv("HOST_MAP")
	if hostMapJSON == "" {
		log.Fatal("HOST_MAP env is required")
	}
	if err := json.Unmarshal([]byte(hostMapJSON), &hostMap); err != nil {
		log.Fatalf("Failed to parse HOST_MAP: %v", err)
	}

	sshUser = os.Getenv("SSH_USER")
	if sshUser == "" {
		sshUser = "isucon"
	}

	mux := http.NewServeMux()

	// MCP Streamable HTTP endpoint
	mux.HandleFunc("/mcp", handleMCP)

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("SSH MCP Server starting on :%s with hosts: %v", port, hostMap)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

// loadSSHSigner fetches the SSH private key from Azure Key Vault.
func loadSSHSigner() (ssh.Signer, error) {
	var err error
	sshSignerOnce.Do(func() {
		// Try env var first (for local dev)
		if keyData := os.Getenv("SSH_PRIVATE_KEY"); keyData != "" {
			sshSigner, err = ssh.ParsePrivateKey([]byte(keyData))
			return
		}

		// Fetch from Azure Key Vault
		kvURL := os.Getenv("AZURE_KEY_VAULT_URL")
		secretName := os.Getenv("SSH_KEY_SECRET_NAME")
		if kvURL == "" || secretName == "" {
			err = fmt.Errorf("AZURE_KEY_VAULT_URL and SSH_KEY_SECRET_NAME are required")
			return
		}

		var cred *azidentity.DefaultAzureCredential
		cred, err = azidentity.NewDefaultAzureCredential(nil)
		if err != nil {
			return
		}

		client, clientErr := azsecrets.NewClient(kvURL, cred, nil)
		if clientErr != nil {
			err = clientErr
			return
		}

		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		resp, getErr := client.GetSecret(ctx, secretName, "", nil)
		if getErr != nil {
			err = fmt.Errorf("failed to get secret %s: %w", secretName, getErr)
			return
		}

		sshSigner, err = ssh.ParsePrivateKey([]byte(*resp.Value))
	})

	return sshSigner, err
}

// resolveHost resolves a host alias or IP to an IP address.
func resolveHost(host string) (string, error) {
	if ip, ok := hostMap[host]; ok {
		return ip, nil
	}
	// Check if it's already an IP in the hostMap values
	for _, ip := range hostMap {
		if ip == host {
			return ip, nil
		}
	}
	return "", fmt.Errorf("unknown host: %s (known: %v)", host, hostMap)
}

// execSSH executes a command on a remote host via SSH.
func execSSH(host, command string) (stdout, stderr string, exitCode int, err error) {
	signer, err := loadSSHSigner()
	if err != nil {
		return "", "", -1, fmt.Errorf("failed to load SSH key: %w", err)
	}

	ip, err := resolveHost(host)
	if err != nil {
		return "", "", -1, err
	}

	config := &ssh.ClientConfig{
		User: sshUser,
		Auth: []ssh.AuthMethod{
			ssh.PublicKeys(signer),
		},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         10 * time.Second,
	}

	addr := net.JoinHostPort(ip, "22")
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return "", "", -1, fmt.Errorf("SSH dial to %s failed: %w", addr, err)
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return "", "", -1, fmt.Errorf("SSH session failed: %w", err)
	}
	defer session.Close()

	var stdoutBuf, stderrBuf bytes.Buffer
	session.Stdout = &stdoutBuf
	session.Stderr = &stderrBuf

	exitCode = 0
	if runErr := session.Run(command); runErr != nil {
		if exitErr, ok := runErr.(*ssh.ExitError); ok {
			exitCode = exitErr.ExitStatus()
		} else {
			return "", "", -1, fmt.Errorf("SSH run failed: %w", runErr)
		}
	}

	return stdoutBuf.String(), stderrBuf.String(), exitCode, nil
}

// ============================================================
// MCP Protocol (Streamable HTTP, simplified)
// ============================================================

type mcpRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type mcpResponse struct {
	JSONRPC string      `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  interface{} `json:"result,omitempty"`
	Error   *mcpError   `json:"error,omitempty"`
}

type mcpError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func handleMCP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	var req mcpRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, nil, -32700, "Parse error")
		return
	}

	switch req.Method {
	case "initialize":
		handleInitialize(w, &req)
	case "tools/list":
		handleToolsList(w, &req)
	case "tools/call":
		handleToolsCall(w, &req)
	default:
		writeError(w, req.ID, -32601, fmt.Sprintf("Method not found: %s", req.Method))
	}
}

func handleInitialize(w http.ResponseWriter, req *mcpRequest) {
	writeResult(w, req.ID, map[string]interface{}{
		"protocolVersion": "2025-03-26",
		"capabilities": map[string]interface{}{
			"tools": map[string]interface{}{},
		},
		"serverInfo": map[string]interface{}{
			"name":    "ssh-mcp-server",
			"version": "0.1.0",
		},
	})
}

func handleToolsList(w http.ResponseWriter, req *mcpRequest) {
	hosts := make([]string, 0, len(hostMap))
	for k := range hostMap {
		hosts = append(hosts, k)
	}

	writeResult(w, req.ID, map[string]interface{}{
		"tools": []map[string]interface{}{
			{
				"name":        "exec",
				"description": fmt.Sprintf("Execute a shell command on a remote host via SSH. Available hosts: %s", strings.Join(hosts, ", ")),
				"inputSchema": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"host": map[string]interface{}{
							"type":        "string",
							"description": fmt.Sprintf("Target host alias (%s) or private IP", strings.Join(hosts, ", ")),
						},
						"command": map[string]interface{}{
							"type":        "string",
							"description": "Shell command to execute",
						},
					},
					"required": []string{"host", "command"},
				},
			},
		},
	})
}

type execParams struct {
	Host    string `json:"host"`
	Command string `json:"command"`
}

func handleToolsCall(w http.ResponseWriter, req *mcpRequest) {
	var params struct {
		Name      string          `json:"name"`
		Arguments json.RawMessage `json:"arguments"`
	}
	if err := json.Unmarshal(req.Params, &params); err != nil {
		writeError(w, req.ID, -32602, "Invalid params")
		return
	}

	if params.Name != "exec" {
		writeError(w, req.ID, -32602, fmt.Sprintf("Unknown tool: %s", params.Name))
		return
	}

	var args execParams
	if err := json.Unmarshal(params.Arguments, &args); err != nil {
		writeError(w, req.ID, -32602, "Invalid exec arguments")
		return
	}

	if args.Host == "" || args.Command == "" {
		writeError(w, req.ID, -32602, "host and command are required")
		return
	}

	log.Printf("exec: host=%s command=%q", args.Host, args.Command)

	stdout, stderr, exitCode, err := execSSH(args.Host, args.Command)
	if err != nil {
		writeResult(w, req.ID, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": fmt.Sprintf("Error: %v", err),
				},
			},
			"isError": true,
		})
		return
	}

	var output strings.Builder
	if stdout != "" {
		output.WriteString(stdout)
	}
	if stderr != "" {
		if output.Len() > 0 {
			output.WriteString("\n--- stderr ---\n")
		}
		output.WriteString(stderr)
	}
	if exitCode != 0 {
		output.WriteString(fmt.Sprintf("\n[exit code: %d]", exitCode))
	}

	writeResult(w, req.ID, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": output.String(),
			},
		},
		"isError": exitCode != 0,
	})
}

func writeResult(w http.ResponseWriter, id json.RawMessage, result interface{}) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(mcpResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	})
}

func writeError(w http.ResponseWriter, id json.RawMessage, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(mcpResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &mcpError{Code: code, Message: message},
	})
}
