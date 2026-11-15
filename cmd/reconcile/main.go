package main

import (
	"encoding/json"
	"fmt"
	"os"

	"github.com/dynamiscode/release-publication-prototype/internal/releaseplan"
)

func main() {
	var request releaseplan.Request
	if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil {
		fatal(err)
	}
	plan, err := releaseplan.Reconcile(request)
	if err != nil {
		fatal(err)
	}
	if err := json.NewEncoder(os.Stdout).Encode(plan); err != nil {
		fatal(err)
	}
}

func fatal(err error) {
	fmt.Fprintln(os.Stderr, err)
	os.Exit(1)
}
