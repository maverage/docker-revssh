// Minimal static non-login shell for images without /bin/false.
// OpenSSH checks that the configured shell exists and is executable,
// even when SSH session channels are disabled.
package main

import "os"

func main() { os.Exit(1) }
