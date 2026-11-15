package main

import (
	"fmt"
	"runtime"
)

var (
	version   = "dev"
	sourceSHA = "unknown"
)

func main() {
	fmt.Printf("synthetic release=%s source=%s os=%s arch=%s\n", version, sourceSHA, runtime.GOOS, runtime.GOARCH)
}
