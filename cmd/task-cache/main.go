package main

import (
	"archive/tar"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

	"github.com/go-task/task/v3/taskfile/ast"
	"github.com/ulikunitz/xz"
	"go.yaml.in/yaml/v3"
)

const cacheDir = ".cache/build"

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "task-cache: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	taskName := flag.String("task", "build", "Task name to cache")
	flag.Parse()

	buildCmd := flag.Args()
	if len(buildCmd) == 0 {
		return errors.New("missing build command after --")
	}

	task, err := readTask(*taskName)
	if err != nil {
		return err
	}

	generated, err := generatedPaths(task)
	if err != nil {
		return err
	}

	key, err := readTaskChecksum(*taskName)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(cacheDir, 0o755); err != nil {
		return err
	}

	archivePath := filepath.Join(cacheDir, key+".tar.xz")
	if _, err := os.Stat(archivePath); err == nil {
		fmt.Printf("Restoring generated outputs from %s\n", archivePath)
		if err := extractArchive(archivePath); err != nil {
			return err
		}
		return verifyGenerated(generated)
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}

	fmt.Printf("No archive for Task hash %s; running build command\n", key)
	if err := runCommand(buildCmd); err != nil {
		return err
	}
	if err := verifyGenerated(generated); err != nil {
		return err
	}
	if err := createArchive(archivePath, generated); err != nil {
		return err
	}
	fmt.Printf("Saved generated outputs to %s\n", archivePath)
	return nil
}

func readTask(taskName string) (*ast.Task, error) {
	data, err := os.ReadFile("Taskfile.yml")
	if err != nil {
		return nil, err
	}

	var tf ast.Taskfile
	if err := yaml.Unmarshal(data, &tf); err != nil {
		return nil, err
	}

	task, ok := tf.Tasks.Get(taskName)
	if !ok {
		return nil, fmt.Errorf("task %q not found", taskName)
	}
	return task, nil
}

func readTaskChecksum(taskName string) (string, error) {
	checksumPath := filepath.Join(".task", "checksum", taskName)
	data, err := os.ReadFile(checksumPath)
	if err != nil {
		return "", fmt.Errorf("read Task checksum %s: %w", checksumPath, err)
	}

	key := strings.TrimSpace(string(data))
	if key == "" {
		return "", fmt.Errorf("Task checksum %s is empty", checksumPath)
	}
	return key, nil
}

func generatedPaths(task *ast.Task) ([]string, error) {
	if len(task.Generates) == 0 {
		return nil, errors.New("task has no generates entries")
	}

	var paths []string
	for _, generate := range task.Generates {
		if generate == nil || generate.Negate {
			continue
		}
		if hasMeta(generate.Glob) {
			matches, err := filepath.Glob(generate.Glob)
			if err != nil {
				return nil, err
			}
			paths = append(paths, matches...)
			continue
		}
		paths = append(paths, generate.Glob)
	}

	if len(paths) == 0 {
		return nil, errors.New("task has no generated output paths")
	}
	return paths, nil
}

func hasMeta(pattern string) bool {
	return strings.ContainsAny(pattern, "*?[")
}

func runCommand(args []string) error {
	cmd := exec.Command(args[0], args[1:]...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func verifyGenerated(paths []string) error {
	for _, output := range paths {
		info, err := os.Stat(output)
		if err != nil {
			return fmt.Errorf("generated output %s: %w", output, err)
		}
		if info.IsDir() {
			return fmt.Errorf("generated output %s is a directory", output)
		}
	}
	return nil
}

func createArchive(archivePath string, files []string) error {
	tmp, err := os.CreateTemp(filepath.Dir(archivePath), filepath.Base(archivePath)+".*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)

	xzWriter, err := xz.NewWriter(tmp)
	if err != nil {
		tmp.Close()
		return err
	}
	tarWriter := tar.NewWriter(xzWriter)

	for _, file := range files {
		if err := addFile(tarWriter, file); err != nil {
			tarWriter.Close()
			xzWriter.Close()
			tmp.Close()
			return err
		}
	}

	if err := tarWriter.Close(); err != nil {
		xzWriter.Close()
		tmp.Close()
		return err
	}
	if err := xzWriter.Close(); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, archivePath)
}

func addFile(tarWriter *tar.Writer, file string) error {
	info, err := os.Stat(file)
	if err != nil {
		return err
	}

	header, err := tar.FileInfoHeader(info, "")
	if err != nil {
		return err
	}
	header.Name = filepath.ToSlash(file)

	if err := tarWriter.WriteHeader(header); err != nil {
		return err
	}

	f, err := os.Open(file)
	if err != nil {
		return err
	}
	defer f.Close()

	_, err = io.Copy(tarWriter, f)
	return err
}

func extractArchive(archivePath string) error {
	f, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer f.Close()

	xzReader, err := xz.NewReader(f)
	if err != nil {
		return err
	}
	tarReader := tar.NewReader(xzReader)

	for {
		header, err := tarReader.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		if err := extractFile(tarReader, header); err != nil {
			return err
		}
	}
}

func extractFile(reader io.Reader, header *tar.Header) error {
	target, err := cleanArchivePath(header.Name)
	if err != nil {
		return err
	}

	if header.Typeflag != tar.TypeReg {
		return fmt.Errorf("unsupported archive entry %s", header.Name)
	}

	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}

	out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode))
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, reader)
	return err
}

func cleanArchivePath(name string) (string, error) {
	clean := path.Clean(name)
	if clean == "." || strings.HasPrefix(clean, "../") || path.IsAbs(clean) {
		return "", fmt.Errorf("unsafe archive path %s", name)
	}
	return filepath.FromSlash(clean), nil
}
