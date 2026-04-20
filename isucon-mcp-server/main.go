package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azidentity"
	"github.com/Azure/azure-sdk-for-go/sdk/security/keyvault/azsecrets"
	"github.com/Azure/azure-sdk-for-go/sdk/storage/azblob"
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

// blobClient is the Azure Blob Storage client for notes.
var blobClient *azblob.Client

// blobContainerName is the container name for notes.
const blobContainerName = "notes"

// benchHistoryFile is the path on bench VM where benchmark history is stored.
const benchHistoryFile = "/home/isucon/benchmark-history.jsonl"

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

	// Initialize Azure Blob Storage client for notes
	if storageURL := os.Getenv("AZURE_STORAGE_ACCOUNT_URL"); storageURL != "" {
		cred, credErr := azidentity.NewDefaultAzureCredential(nil)
		if credErr != nil {
			log.Printf("WARNING: Failed to create Azure credential for storage: %v", credErr)
		} else {
			client, clientErr := azblob.NewClient(storageURL, cred, nil)
			if clientErr != nil {
				log.Printf("WARNING: Failed to create blob client: %v", clientErr)
			} else {
				blobClient = client
				log.Printf("Azure Blob Storage initialized: %s", storageURL) // #nosec G706 -- storageURL is from env var, not user input
			}
		}
	} else {
		log.Println("WARNING: AZURE_STORAGE_ACCOUNT_URL not set, note tools will be unavailable")
	}

	mux := http.NewServeMux()

	// MCP Streamable HTTP endpoint (authenticated)
	mux.HandleFunc("/mcp", requireAuth(handleMCP))

	// Health check
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = fmt.Fprint(w, "ok")
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	log.Printf("ISUCON MCP Server starting on :%s with hosts: %v (auth: %v)", port, hostMap, apiKey != "") // #nosec G706 -- port and hostMap are from env vars
	server := &http.Server{
		Addr:              ":" + port,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil {
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
		HostKeyCallback: ssh.InsecureIgnoreHostKey(), // #nosec G106 -- internal network, host key verification not needed
		Timeout:         10 * time.Second,
	}

	addr := net.JoinHostPort(ip, "22")
	client, err := ssh.Dial("tcp", addr, config)
	if err != nil {
		return "", "", -1, fmt.Errorf("SSH dial to %s failed: %w", addr, err)
	}
	defer func() { _ = client.Close() }()

	session, err := client.NewSession()
	if err != nil {
		return "", "", -1, fmt.Errorf("SSH session failed: %w", err)
	}
	defer func() { _ = session.Close() }()

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

	// Determine admin mode from X-Admin-Mode header
	adminMode := strings.EqualFold(r.Header.Get("X-Admin-Mode"), "true")

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
		handleToolsList(w, &req, adminMode)
	case "tools/call":
		handleToolsCall(w, &req, adminMode)
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
			"version": "0.3.0",
		},
	})
}

func handleToolsList(w http.ResponseWriter, req *mcpRequest, adminMode bool) {
	// Build host list based on admin mode
	hosts := make([]string, 0, len(hostMap))
	for k := range hostMap {
		if !adminMode && k == benchHost {
			continue // hide bench from non-admin
		}
		hosts = append(hosts, k)
	}
	sort.Strings(hosts)

	execDesc := fmt.Sprintf("Execute a shell command on a remote host via SSH. Available hosts: %s", strings.Join(hosts, ", "))
	if !adminMode {
		execDesc += fmt.Sprintf(". Note: %s (benchmark VM) is not available in non-admin mode.", benchHost)
	}

	tools := []map[string]interface{}{
		{
			"name":        "exec",
			"description": execDesc,
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
		{
			"name":        "benchmark_history",
			"description": "View benchmark run history with scores. Shows a table of past runs and best/worst scores across all runs.",
			"inputSchema": map[string]interface{}{
				"type": "object",
				"properties": map[string]interface{}{
					"limit": map[string]interface{}{
						"type":        "integer",
						"description": "Maximum number of recent runs to display. Defaults to all (up to 50).",
					},
				},
			},
		},
	}

	// Add note tools only if storage is configured
	if blobClient != nil {
		tools = append(tools,
			map[string]interface{}{
				"name":        "note_write",
				"description": "Write or append text to a note. Use for recording findings, changes, and building reports.",
				"inputSchema": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"path": map[string]interface{}{
							"type":        "string",
							"description": "Note file path (e.g., 'report.md', 'logs/attempt-1.txt')",
						},
						"content": map[string]interface{}{
							"type":        "string",
							"description": "Text content to write",
						},
						"append": map[string]interface{}{
							"type":        "boolean",
							"description": "If true, append to existing note instead of overwriting. Default: false",
						},
					},
					"required": []string{"path", "content"},
				},
			},
			map[string]interface{}{
				"name":        "note_read",
				"description": "Read the contents of a note.",
				"inputSchema": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"path": map[string]interface{}{
							"type":        "string",
							"description": "Note file path to read",
						},
						"head": map[string]interface{}{
							"type":        "integer",
							"description": "Return only the first N lines",
						},
						"tail": map[string]interface{}{
							"type":        "integer",
							"description": "Return only the last N lines",
						},
					},
					"required": []string{"path"},
				},
			},
			map[string]interface{}{
				"name":        "note_list",
				"description": "List all notes. Optionally filter by path prefix.",
				"inputSchema": map[string]interface{}{
					"type": "object",
					"properties": map[string]interface{}{
						"prefix": map[string]interface{}{
							"type":        "string",
							"description": "Filter notes by path prefix (e.g., 'logs/')",
						},
					},
				},
			},
		)
	}

	writeResult(w, req.ID, map[string]interface{}{
		"tools": tools,
	})
}

type execParams struct {
	Host    string `json:"host"`
	Command string `json:"command"`
}

func handleToolsCall(w http.ResponseWriter, req *mcpRequest, adminMode bool) {
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
		handleExecTool(w, req.ID, params.Arguments, adminMode)
	case "benchmark_start":
		handleBenchmarkStart(w, req.ID, params.Arguments)
	case "benchmark_status":
		handleBenchmarkStatus(w, req.ID, params.Arguments)
	case "benchmark_history":
		handleBenchmarkHistory(w, req.ID, params.Arguments)
	case "note_write":
		handleNoteWrite(w, req.ID, params.Arguments)
	case "note_read":
		handleNoteRead(w, req.ID, params.Arguments)
	case "note_list":
		handleNoteList(w, req.ID, params.Arguments)
	default:
		writeError(w, req.ID, -32602, fmt.Sprintf("Unknown tool: %s", params.Name))
	}
}

func handleExecTool(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage, adminMode bool) {
	var args execParams
	if err := json.Unmarshal(arguments, &args); err != nil {
		writeError(w, id, -32602, "Invalid exec arguments")
		return
	}

	if args.Host == "" || args.Command == "" {
		writeError(w, id, -32602, "host and command are required")
		return
	}

	// Admin mode check: only admin can exec on bench VM
	if args.Host == benchHost && !adminMode {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": fmt.Sprintf("Error: exec on %s (benchmark VM) requires admin mode. Use contest VMs (vm1, vm2, vm3) instead.", benchHost),
				},
			},
			"isError": true,
		})
		return
	}

	log.Printf("exec: host=%s command=%q admin=%v", args.Host, args.Command, adminMode) // #nosec G706 -- args are validated above

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
		fmt.Fprintf(&output, "\n[exit code: %d]", exitCode)
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
		_ = json.Unmarshal(arguments, &args)
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

		job.EndedAt = &now
		benchRunning = false

		if err != nil {
			job.Status = "failed"
			job.Error = err.Error()
			log.Printf("benchmark_start: job_id=%s failed: %v", jobID, err)
			benchMu.Unlock()
			appendBenchmarkHistory(job)
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
		benchMu.Unlock()

		// Persist history to bench VM (best-effort)
		appendBenchmarkHistory(job)
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
		_ = json.Unmarshal(arguments, &args)
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
// It looks for patterns like "score: 3600", "Score: 3600", or "スコア: 3600".
func parseScore(output string) (int, bool) {
	lines := strings.Split(output, "\n")
	for _, line := range lines {
		lower := strings.ToLower(line)
		// Check for Japanese "スコア" or English "score"
		var rest string
		if idx := strings.Index(line, "スコア"); idx >= 0 {
			rest = line[idx+len("スコア"):]
		} else if idx := strings.Index(lower, "score"); idx >= 0 {
			rest = line[idx+len("score"):]
		} else {
			continue
		}
		var score int
		// Try ": 1234", ":1234", "= 1234", "=1234" patterns
		for _, sep := range []string{": ", ":", "= ", "="} {
			if n, err := fmt.Sscanf(rest, sep+"%d", &score); n == 1 && err == nil {
				return score, true
			}
		}
	}
	return 0, false
}

// ============================================================
// Benchmark history
// ============================================================

// appendBenchmarkHistory persists a benchmark result to the bench VM.
// This is best-effort — failures are logged but don't affect the benchmark result.
func appendBenchmarkHistory(job *benchmarkJob) {
	scoreStr := "null"
	if job.Score != nil {
		scoreStr = strconv.Itoa(*job.Score)
	}
	passedStr := "null"
	if job.Passed != nil {
		passedStr = strconv.FormatBool(*job.Passed)
	}
	endedAtStr := ""
	if job.EndedAt != nil {
		endedAtStr = job.EndedAt.Format(time.RFC3339)
	}

	record := fmt.Sprintf(`{"job_id":"%s","status":"%s","score":%s,"passed":%s,"started_at":"%s","ended_at":"%s"}`,
		job.ID, job.Status, scoreStr, passedStr, job.StartedAt.Format(time.RFC3339), endedAtStr)

	cmd := fmt.Sprintf("echo '%s' >> %s", record, benchHistoryFile)
	_, _, _, err := execSSH(benchHost, cmd)
	if err != nil {
		log.Printf("WARNING: Failed to append benchmark history: %v", err)
	}
}

func handleBenchmarkHistory(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	var args struct {
		Limit int `json:"limit"`
	}
	if arguments != nil {
		_ = json.Unmarshal(arguments, &args)
	}

	// Read history file from bench VM
	stdout, _, _, err := execSSH(benchHost, fmt.Sprintf("cat %s 2>/dev/null || echo ''", benchHistoryFile))
	if err != nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": fmt.Sprintf("Error reading benchmark history: %v", err),
				},
			},
			"isError": true,
		})
		return
	}

	type historyEntry struct {
		JobID     string `json:"job_id"`
		Status    string `json:"status"`
		Score     *int   `json:"score"`
		Passed    *bool  `json:"passed"`
		StartedAt string `json:"started_at"`
		EndedAt   string `json:"ended_at"`
	}

	var entries []historyEntry
	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var entry historyEntry
		if err := json.Unmarshal([]byte(line), &entry); err != nil {
			continue // skip malformed lines
		}
		entries = append(entries, entry)
	}

	if len(entries) == 0 {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": "No benchmark history found. Run benchmark_start to create history.",
				},
			},
		})
		return
	}

	// Sort by started_at descending (newest first)
	sort.Slice(entries, func(i, j int) bool {
		return entries[i].StartedAt > entries[j].StartedAt
	})

	totalRuns := len(entries)

	// Find best/worst across ALL runs
	var bestScore, worstScore int
	var bestJobID, worstJobID string
	bestInitialized := false
	for _, e := range entries {
		if e.Score != nil {
			if !bestInitialized {
				bestScore = *e.Score
				worstScore = *e.Score
				bestJobID = e.JobID
				worstJobID = e.JobID
				bestInitialized = true
			} else {
				if *e.Score > bestScore {
					bestScore = *e.Score
					bestJobID = e.JobID
				}
				if *e.Score < worstScore {
					worstScore = *e.Score
					worstJobID = e.JobID
				}
			}
		}
	}

	// Apply limit
	displayEntries := entries
	if args.Limit > 0 && args.Limit < len(entries) {
		displayEntries = entries[:args.Limit]
	}

	var text strings.Builder
	if args.Limit > 0 && args.Limit < totalRuns {
		fmt.Fprintf(&text, "=== Benchmark History (latest %d of %d runs) ===\n\n", len(displayEntries), totalRuns)
	} else {
		fmt.Fprintf(&text, "=== Benchmark History (%d runs) ===\n\n", totalRuns)
	}

	// Table header
	fmt.Fprintf(&text, "%-4s %-18s %8s %8s %-22s %10s\n", "#", "job_id", "score", "passed", "started_at", "duration")
	for i, e := range displayEntries {
		scoreStr := "-"
		if e.Score != nil {
			scoreStr = strconv.Itoa(*e.Score)
		}
		passedStr := "-"
		if e.Passed != nil {
			passedStr = strconv.FormatBool(*e.Passed)
		}
		durationStr := "-"
		if e.StartedAt != "" && e.EndedAt != "" {
			if st, err1 := time.Parse(time.RFC3339, e.StartedAt); err1 == nil {
				if et, err2 := time.Parse(time.RFC3339, e.EndedAt); err2 == nil {
					durationStr = et.Sub(st).Round(time.Second).String()
				}
			}
		}
		fmt.Fprintf(&text, "%-4d %-18s %8s %8s %-22s %10s\n", i+1, e.JobID, scoreStr, passedStr, e.StartedAt, durationStr)
	}

	if bestInitialized {
		fmt.Fprintf(&text, "\nAll %d runs — Best: %d (%s), Worst: %d (%s)\n", totalRuns, bestScore, bestJobID, worstScore, worstJobID)
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

// ============================================================
// Note tools (Azure Blob Storage)
// ============================================================

func handleNoteWrite(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	if blobClient == nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": "Error: Note storage is not configured. Set AZURE_STORAGE_ACCOUNT_URL.",
				},
			},
			"isError": true,
		})
		return
	}

	var args struct {
		Path    string `json:"path"`
		Content string `json:"content"`
		Append  bool   `json:"append"`
	}
	if err := json.Unmarshal(arguments, &args); err != nil {
		writeError(w, id, -32602, "Invalid note_write arguments")
		return
	}

	if args.Path == "" || args.Content == "" {
		writeError(w, id, -32602, "path and content are required")
		return
	}

	// Sanitize path
	args.Path = strings.TrimPrefix(args.Path, "/")
	if strings.Contains(args.Path, "..") {
		writeError(w, id, -32602, "path must not contain '..'")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	var data []byte
	if args.Append {
		// Download existing content first
		resp, err := blobClient.DownloadStream(ctx, blobContainerName, args.Path, nil)
		if err == nil {
			existing, readErr := io.ReadAll(resp.Body)
			_ = resp.Body.Close()
			if readErr == nil {
				data = append(existing, []byte(args.Content)...)
			} else {
				data = []byte(args.Content)
			}
		} else {
			// Blob doesn't exist yet, just write new content
			data = []byte(args.Content)
		}
	} else {
		data = []byte(args.Content)
	}

	_, err := blobClient.UploadBuffer(ctx, blobContainerName, args.Path, data, nil)
	if err != nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": fmt.Sprintf("Error writing note: %v", err),
				},
			},
			"isError": true,
		})
		return
	}

	writeResult(w, id, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": fmt.Sprintf("Saved to %s (%d bytes)", args.Path, len(data)),
			},
		},
	})
}

func handleNoteRead(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	if blobClient == nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": "Error: Note storage is not configured. Set AZURE_STORAGE_ACCOUNT_URL.",
				},
			},
			"isError": true,
		})
		return
	}

	var args struct {
		Path string `json:"path"`
		Head int    `json:"head"`
		Tail int    `json:"tail"`
	}
	if err := json.Unmarshal(arguments, &args); err != nil {
		writeError(w, id, -32602, "Invalid note_read arguments")
		return
	}

	if args.Path == "" {
		writeError(w, id, -32602, "path is required")
		return
	}
	if args.Head > 0 && args.Tail > 0 {
		writeError(w, id, -32602, "head and tail are mutually exclusive")
		return
	}

	args.Path = strings.TrimPrefix(args.Path, "/")
	if strings.Contains(args.Path, "..") {
		writeError(w, id, -32602, "path must not contain '..'")
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	resp, err := blobClient.DownloadStream(ctx, blobContainerName, args.Path, nil)
	if err != nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": fmt.Sprintf("Error reading note: %v", err),
				},
			},
			"isError": true,
		})
		return
	}

	body, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": fmt.Sprintf("Error reading note body: %v", err),
				},
			},
			"isError": true,
		})
		return
	}

	content := string(body)

	// Apply head/tail line filtering
	if args.Head > 0 || args.Tail > 0 {
		lines := strings.Split(content, "\n")
		if args.Head > 0 {
			if args.Head < len(lines) {
				lines = lines[:args.Head]
			}
		} else if args.Tail > 0 {
			if args.Tail < len(lines) {
				lines = lines[len(lines)-args.Tail:]
			}
		}
		content = strings.Join(lines, "\n")
	}

	writeResult(w, id, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": content,
			},
		},
	})
}

func handleNoteList(w http.ResponseWriter, id json.RawMessage, arguments json.RawMessage) {
	if blobClient == nil {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": "Error: Note storage is not configured. Set AZURE_STORAGE_ACCOUNT_URL.",
				},
			},
			"isError": true,
		})
		return
	}

	var args struct {
		Prefix string `json:"prefix"`
	}
	if arguments != nil {
		_ = json.Unmarshal(arguments, &args)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	opts := &azblob.ListBlobsFlatOptions{}
	if args.Prefix != "" {
		opts.Prefix = &args.Prefix
	}
	pager := blobClient.NewListBlobsFlatPager(blobContainerName, opts)

	var text strings.Builder
	count := 0
	for pager.More() {
		page, err := pager.NextPage(ctx)
		if err != nil {
			writeResult(w, id, map[string]interface{}{
				"content": []map[string]interface{}{
					{
						"type": "text",
						"text": fmt.Sprintf("Error listing notes: %v", err),
					},
				},
				"isError": true,
			})
			return
		}
		for _, blob := range page.Segment.BlobItems {
			size := int64(0)
			if blob.Properties.ContentLength != nil {
				size = *blob.Properties.ContentLength
			}
			lastMod := ""
			if blob.Properties.LastModified != nil {
				lastMod = blob.Properties.LastModified.Format(time.RFC3339)
			}
			fmt.Fprintf(&text, "%-40s %8d bytes  %s\n", *blob.Name, size, lastMod)
			count++
		}
	}

	if count == 0 {
		writeResult(w, id, map[string]interface{}{
			"content": []map[string]interface{}{
				{
					"type": "text",
					"text": "No notes found.",
				},
			},
		})
		return
	}

	header := fmt.Sprintf("=== Notes (%d files) ===\n\n", count)
	writeResult(w, id, map[string]interface{}{
		"content": []map[string]interface{}{
			{
				"type": "text",
				"text": header + text.String(),
			},
		},
	})
}

func writeResult(w http.ResponseWriter, id json.RawMessage, result interface{}) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(mcpResponse{
		JSONRPC: "2.0",
		ID:      id,
		Result:  result,
	})
}

func writeError(w http.ResponseWriter, id json.RawMessage, code int, message string) {
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(mcpResponse{
		JSONRPC: "2.0",
		ID:      id,
		Error:   &mcpError{Code: code, Message: message},
	})
}
