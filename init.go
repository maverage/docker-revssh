package main

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var nameRE = regexp.MustCompile(`^[A-Za-z0-9_-]+$`)

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "revssh-init: "+format+"\n", a...)
	os.Exit(1)
}
func run(path string, args ...string) {
	c := exec.Command(path, args...)
	c.Stderr = os.Stderr
	if err := c.Run(); err != nil {
		fail("%s: %v", path, err)
	}
}

// healthcheck verifies sshd is accepting connections and emitting its SSH banner.
// This command runs without configuration writes or SSH authentication.
func healthcheck() {
	conn, err := net.DialTimeout("tcp", "127.0.0.1:2222", 3*time.Second)
	if err != nil {
		fail("healthcheck connection: %v", err)
	}
	defer conn.Close()
	if err := conn.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		fail("healthcheck deadline: %v", err)
	}
	banner, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil || !strings.HasPrefix(banner, "SSH-2.0-") {
		fail("healthcheck: expected SSH-2.0 banner")
	}
}

func main() {
	if len(os.Args) == 2 && os.Args[1] == "healthcheck" {
		healthcheck()
		return
	}
	if len(os.Args) != 1 {
		fail("unknown arguments")
	}
	const data = "/data"
	const runtime = "/run/sshd"
	if err := os.MkdirAll(data, 0700); err != nil {
		fail("mkdir data: %v", err)
	}
	if err := os.MkdirAll(runtime, 0700); err != nil {
		fail("mkdir run: %v", err)
	}
	if err := os.Chmod(data, 0700); err != nil {
		fail("chmod data: %v", err)
	}
	if err := os.Chmod(runtime, 0700); err != nil {
		fail("chmod run: %v", err)
	}
	host := data + "/ssh_host_ed25519_key"
	if _, err := os.Stat(host); errors.Is(err, os.ErrNotExist) {
		if os.Getenv("REVSSH_HOST_KEY_MODE") == "embedded" {
			fail("embedded host key missing; /data may be masked by a mount (refusing to rotate identity)")
		}
		run("/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", host)
	} else if err != nil {
		fail("host key: %v", err)
	}
	if err := os.Chmod(host, 0600); err != nil {
		fail("chmod host key: %v", err)
	}
	var raw []byte
	var err error
	if file := os.Getenv("TUNNELS_FILE"); file != "" {
		raw, err = os.ReadFile(file)
	} else {
		raw = []byte(os.Getenv("TUNNELS"))
	}
	if err != nil {
		fail("read tunnel configuration: %v", err)
	}
	var buf bytes.Buffer
	keys := map[[32]byte]bool{}
	portsSeen := map[int]bool{}
	names := map[string]bool{}
	scanner := bufio.NewScanner(bytes.NewReader(raw))
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	count := 0
	for scanner.Scan() {
		s := strings.TrimSpace(scanner.Text())
		if s == "" || strings.HasPrefix(s, "#") {
			continue
		}
		fields := strings.SplitN(s, "|", 4)
		if len(fields) != 3 {
			fail("expected name|ports|public-key on line %d", count+1)
		}
		name, portCSV, key := strings.TrimSpace(fields[0]), strings.TrimSpace(fields[1]), strings.TrimSpace(fields[2])
		if !nameRE.MatchString(name) || names[name] {
			fail("invalid/duplicate endpoint name %q", name)
		}
		names[name] = true
		parts := strings.Fields(key)
		if len(parts) < 2 || parts[0] != "ssh-ed25519" {
			fail("Ed25519 public key required for %s", name)
		}
		decoded, err := base64.StdEncoding.DecodeString(parts[1])
		if err != nil || len(decoded) < 16 {
			fail("malformed public key for %s", name)
		}
		// OpenSSH validates the decoded public key, including the embedded key type.
		keyfile, err := os.CreateTemp(runtime, "keycheck-")
		if err != nil {
			fail("temp key: %v", err)
		}
		if _, err = keyfile.WriteString(parts[0] + " " + parts[1] + "\n"); err != nil {
			fail("write key: %v", err)
		}
		keyfile.Close()
		check := exec.Command("/usr/bin/ssh-keygen", "-lf", keyfile.Name(), "-E", "sha256")
		_, err = check.CombinedOutput()
		os.Remove(keyfile.Name())
		if err != nil {
			fail("invalid OpenSSH public key for %s", name)
		}
		fingerprint := sha256.Sum256(decoded)
		if keys[fingerprint] {
			fail("duplicate public key for %s", name)
		}
		keys[fingerprint] = true
		ptexts := strings.Split(portCSV, ",")
		if len(ptexts) == 0 {
			fail("missing port for %s", name)
		}
		opts := "restrict,port-forwarding"
		for _, ptext := range ptexts {
			if ptext == "" {
				fail("empty port for %s", name)
			}
			for _, c := range ptext {
				if c < '0' || c > '9' {
					fail("invalid port for %s", name)
				}
			}
			port, e := strconv.Atoi(ptext)
			if e != nil || port < 1024 || port > 65535 || port == 2222 {
				fail("invalid port %q for %s", ptext, name)
			}
			if portsSeen[port] {
				fail("duplicate reverse port %d", port)
			}
			portsSeen[port] = true
			opts += fmt.Sprintf(",permitlisten=\"0.0.0.0:%d\"", port)
		}
		// Drop untrusted key comments; emit only the validated key type and material.
		fmt.Fprintf(&buf, "%s %s %s\n", opts, parts[0], parts[1])
		count++
	}
	if err := scanner.Err(); err != nil {
		fail("scan configuration: %v", err)
	}
	if count == 0 {
		fail("at least one endpoint is required")
	}
	temp, err := os.CreateTemp(runtime, "authorized_keys-")
	if err != nil {
		fail("create authorized_keys: %v", err)
	}
	if err := temp.Chmod(0600); err != nil {
		fail("chmod authorized_keys: %v", err)
	}
	if _, err := temp.Write(buf.Bytes()); err != nil {
		fail("write authorized_keys: %v", err)
	}
	if err := temp.Close(); err != nil {
		fail("close authorized_keys: %v", err)
	}
	if err := os.Rename(temp.Name(), filepath.Join(runtime, "authorized_keys")); err != nil {
		fail("rename authorized_keys: %v", err)
	}
	run("/usr/sbin/sshd", "-t", "-f", "/etc/ssh/sshd_config")
	fmt.Fprintf(os.Stderr, "revssh-init: starting sshd with %d authorized endpoints\n", count)
	if err := syscall.Exec("/usr/sbin/sshd", []string{"/usr/sbin/sshd", "-D", "-e", "-f", "/etc/ssh/sshd_config"}, os.Environ()); err != nil {
		fail("exec sshd: %v", err)
	}
}
