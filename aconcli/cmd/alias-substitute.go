// Copyright © 2023 Intel Corporation
// SPDX-License-Identifier: Apache-2.0

package cmd

import (
	"fmt"
	"os"
	"path/filepath"

	"aconcli/repo"
	"github.com/spf13/cobra"
)

var substituteAll bool
var refs []string

var aliasCmd = &cobra.Command{
	Use:   "alias-substitute MANIFEST_FILE",
	Short: "Substitute file system layer digests with aliases",
	Long: `
Substitute the digests of file system layers with their aliases
recorded in the manifest files from ACON repository or command
line`,
	Args: cobra.ExactArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		return aliasSubstitute(args)
	},
}

func aliasSubstitute(args []string) error {
	manifestFile = args[0]
	startingDir := filepath.Dir(manifestFile)
	if targetDir != "" {
		startingDir = targetDir
	}
	r, err := repo.FindRepo(startingDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Alias Substitution: %v\n", err)
		return err
	}

	var filter func(*repo.Bundle) bool
	if !substituteAll {
		filter = func(b *repo.Bundle) bool {
			return b.IsSignatureValid()
		}
	}
	if err := r.Alias(manifestFile, filter); err != nil {
		fmt.Fprintf(os.Stderr, "Alias Substitution: %v\n", err)
		return err
	}
	return nil
}

func init() {
	rootCmd.AddCommand(aliasCmd)

	aliasCmd.Flags().StringSliceVarP(&refs, "input", "i", nil,
		"manifest files for alias substitution reference")
	aliasCmd.Flags().BoolVarP(&substituteAll, "all", "a", false,
		"Consider all manifest files, even though there is no associated signature file")
}
