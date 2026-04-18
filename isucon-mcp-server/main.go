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

// apiKey is the required API key for authentication.
var apiKey string

// benchHost is the host alias for the benchmark VM.
var benchHost string

// benchCommand is the command to run the benchmark.
var benchCommand string

// ============================================================
// Benchmark job tracking
// ============================================================

type benchmarkJob struct {
	ID        string     `json:"id"`
	Status    string     `json:"status"` // running, completed, failed
	Score     *int       `json:"score,omitempty"`
	Passed    *bool      `json:"passed,omitempty"`
	Output    string     `json:"output,omitempty"`
	Error     string     `json:"error,omitempty"`
	StartedAt time.Time  `json:"started_at"`
	EndedAt   *time.Time `json:"ended_at,omitempty"`
}

var (
	benchJobs    = make(map[string]*benchmarkJob)
	benchMu      sync.Mutex
	benchRunning bool
)

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

	apiKey = os.Getenv("API_KEY")
	if apiKey == "" {
		log.Println("WARNING: API_KEY not set, server is unauthenticated")
	}

	benchHost = os.Getenv("BENCH_HOST")
	if benchHost == "" {
		benchHost = "bench"
	}

	benchCommand = os.Getenv("BENCH_COMMAND")
	if benchCommand == "" {
		benchCommand = "sudo -u isucon /home/isucon/run-benchmark.sh"
	}

	mux := http.NewServeMux()

	// MCP Streamable HTTP endpoint (authenticated)
	mux.HandleFunc("/mcp", requireAuth(handleMCP))

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, "ok")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("ISUCON MCP Server starting on :%s with hosts: %v (auth: %v)", port, hostMap, apiKey != "")
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
// Authentication middleware
// ============================================================

// requireAuth checks for API key in Authorization: Bearer or X-API-Key header.
func requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if apiKey == "" {
			next(w, r)
			return
		}

		token := ""
		if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
			token = strings.TrimPrefix(auth, "Bearer ")
		}
		if token == "" {
			token = r.Header.Get("X-API-Key")
		}

		if token != apiKey {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}

		next(w, r)
	}
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
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  interface{}     `json:"result,omitempty"`
	Error   *mcpError       `json:"error,omitempty"`
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
	case "notifications/initialized":
		// Client acknowledgment after initialize — no response needed
		w.WriteHeader(http.StatusOK)
		return
	case "ping":
		// SRE Agent sends ping for health checks — return empty result
		writeResult(w, req.ID, map[string]interface{}{})
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
			"name":    "isucon-mcp-server",
			"version": "0.2.0",
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
			{
				"name":        "benchmark_start",
				"description": "Start an ISUCON benchmark run asynchronously. Returns a job ID. Only one benchmark can run at a time.",
				"inputSchema": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"options": map[string]interface{}{
							"type":        "string",
							"description": "Additional options for the benchmark (e.g., '--pretest-only' for validation without load test)",
						},
					},
				},
			},
			{
				"name":        "benchmark_status",
				"description": "Check the status of a benchmark job. Returns score and output when completed.",
				"inputSchema": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"job_id": map[string]interface{}{
							"type":        "string",
							"description": "Benchmark job ID returned by benchmark_start. If omitted, returns the latest job.",
						},
					},
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

	switch params.Name {
	case "exec":
		handleExecTool(w, req.ID, params.Arguments)
	case "benchmark_start":
		handleBenchmarkStart(w, req.ID, params.Arguments)
	case "benchmark_status":
		handleBenchmarkStatus(w, req.ID, params.Arguments)
	default:
		writeError(w, req.ID, -32602, fmt.Sprintf("Unknown tool: %s", params.Name))
	}
}

func handleExecTool(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	var args execParams
	if err := json.Unmarshal(arguments, &args); err != nil {
		writeError(w, id, -32602, "Invalid exec arguments")
		return
	}

	if args.Host == "" || args.Command == "" {
		writeError(w, id, -32602, "host and command are required")
		return
	}

	log.Printf("exec: host=%s command=%q", args.Host, args.Command)

	stdout, stderr, exitCode, err := execSSH(args.Host, args.Command)
	if err != nil {
		writeResult(w, id, map[string]interface{}{
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

	writeResult(w, id, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": output.String(),
			},
		},
		"isError": exitCode != 0,
	})
}

// ============================================================
// Benchmark tools
// ============================================================

func handleBenchmarkStart(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	var args struct {
		Options string `json:"options"`
	}
	if arguments != nil {
		json.Unmarshal(arguments, &args)
	}

	benchMu.Lock()
	if benchRunning {
		benchMu.Unlock()
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": "A benchmark is already running. Use benchmark_status to check progress.",
				},
			},
			"isError": true,
		})
		return
	}

	jobID := time.Now().Format("20060102-150405")
	job := &benchmarkJob{
		ID:        jobID,
		Status:    "running",
		StartedAt: time.Now(),
	}
	benchJobs[jobID] = job
	benchRunning = true
	benchMu.Unlock()

	// Build the command
	cmd := benchCommand
	if args.Options != "" {
		cmd += " " + args.Options
	}

	log.Printf("benchmark_start: job_id=%s command=%q", jobID, cmd)

	// Run benchmark asynchronously
	go func() {
		stdout, stderr, exitCode, err := execSSH(benchHost, cmd)

		now := time.Now()
		benchMu.Lock()
		defer benchMu.Unlock()

		job.EndedAt = &now
		benchRunning = false

		if err != nil {
			job.Status = "failed"
			job.Error = err.Error()
			log.Printf("benchmark_start: job_id=%s failed: %v", jobID, err)
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
		job.Output = output.String()

		if exitCode != 0 {
			job.Status = "failed"
			job.Error = fmt.Sprintf("exit code: %d", exitCode)
			passed := false
			job.Passed = &passed
		} else {
			job.Status = "completed"
			passed := true
			job.Passed = &passed
		}

		// Try to parse score from output
		if score, ok := parseScore(job.Output); ok {
			job.Score = &score
		}

		log.Printf("benchmark_start: job_id=%s status=%s score=%v", jobID, job.Status, job.Score)
	}()

	writeResult(w, id, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": fmt.Sprintf("Benchmark started.\njob_id: %s\nstatus: running", jobID),
			},
		},
	})
}

func handleBenchmarkStatus(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	var args struct {
		JobID string `json:"job_id"`
	}
	if arguments != nil {
		json.Unmarshal(arguments, &args)
	}

	benchMu.Lock()
	defer benchMu.Unlock()

	var job *benchmarkJob

	if args.JobID != "" {
		var ok bool
		job, ok = benchJobs[args.JobID]
		if !ok {
			writeResult(w, id, map[string]interface{}{
				"content": []map[string]interface{}{
					{
						"type": "text",
						"text": fmt.Sprintf("Job not found: %s", args.JobID),
					},
				},
				"isError": true,
			})
			return
		}
	} else {
		// Find the latest job
		var latestTime time.Time
		for _, j := range benchJobs {
			if j.StartedAt.After(latestTime) {
				latestTime = j.StartedAt
				job = j
			}
		}
		if job == nil {
			writeResult(w, id, map[string]interface{}{
				"content": []map[string]interface{}{
					{
						"type": "text",
						"text": "No benchmark jobs found. Use benchmark_start to run a benchmark.",
					},
				},
			})
			return
		}
	}

	var text strings.Builder
	fmt.Fprintf(&text, "job_id: %s\nstatus: %s\nstarted_at: %s\n", job.ID, job.Status, job.StartedAt.Format(time.RFC3339))

	switch job.Status {
	case "running":
		elapsed := time.Since(job.StartedAt).Round(time.Second)
		fmt.Fprintf(&text, "elapsed: %s\n", elapsed)
	case "completed":
		fmt.Fprintf(&text, "ended_at: %s\n", job.EndedAt.Format(time.RFC3339))
		if job.Score != nil {
			fmt.Fprintf(&text, "score: %d\n", *job.Score)
		}
		if job.Passed != nil {
			fmt.Fprintf(&text, "passed: %v\n", *job.Passed)
		}
		if job.Output != "" {
			fmt.Fprintf(&text, "\n--- benchmark output ---\n%s", job.Output)
		}
	case "failed":
		fmt.Fprintf(&text, "ended_at: %s\n", job.EndedAt.Format(time.RFC3339))
		if job.Error != "" {
			fmt.Fprintf(&text, "error: %s\n", job.Error)
		}
		if job.Passed != nil {
			fmt.Fprintf(&text, "passed: %v\n", *job.Passed)
		}
		if job.Output != "" {
			fmt.Fprintf(&text, "\n--- benchmark output ---\n%s", job.Output)
		}
	}

	writeResult(w, id, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": text.String(),
			},
		},
	})
}

// parseScore extracts the score from benchmark output.
// It looks for patterns like "score: 3600" or "Score: 3600".
func parseScore(output string) (int, bool) {
	lines := strings.Split(output, "\n")
	for _, line := range lines {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "score") {
			// Try to find a number after "score"
			idx := strings.Index(lower, "score")
			rest := line[idx:]
			var score int
			// Try "score: 1234" or "score=1234" patterns
			for _, sep := range []string{": ", ":", "= ", "="} {
				if n, err := fmt.Sscanf(rest[len("score"):], sep+"%d", &score); n == 1 && err == nil {
					return score, true
				}
			}
		}
	}
	return 0, false
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
