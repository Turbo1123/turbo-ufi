package main

import (
	"fmt"
	"os"
	"syscall"
)

func restrictProcess() error {
	if os.Geteuid() == 0 {
		if err := syscall.Setgroups([]int{2000, 1004, 3003}); err != nil {
			return err
		}
		if err := syscall.Setgid(2000); err != nil {
			return err
		}
		if err := syscall.Setuid(2000); err != nil {
			return err
		}
	}
	if os.Geteuid() != 2000 {
		return fmt.Errorf("expected Android shell UID, got %d", os.Geteuid())
	}
	return nil
}
