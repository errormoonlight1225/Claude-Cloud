//go:build !darwin

package main

import (
	"fmt"
	"os"
)

func main() {
	fmt.Fprintln(os.Stderr, "awg-root only runs on jailbroken iOS")
	os.Exit(1)
}
