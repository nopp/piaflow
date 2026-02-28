package server

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"noppflow/internal/config"
	"noppflow/internal/pipeline"
)

const k8sRunTimeout = 30 * time.Minute

func appUsesK8sJob(app config.App) bool {
	for _, step := range app.EffectiveSteps() {
		if step.Kind() == "k8s_deploy" {
			return true
		}
	}
	return false
}

func (s *Server) runAppAsK8sJob(runID int64, app config.App, privateKey string, onLogUpdate func(log string)) pipeline.Result {
	namespace := strings.TrimSpace(app.K8sNamespace)
	if namespace == "" {
		return pipeline.Result{Success: false, Log: "k8s namespace is required"}
	}
	serviceAccount := strings.TrimSpace(app.K8sServiceAccount)
	if serviceAccount == "" {
		return pipeline.Result{Success: false, Log: "k8s service account is required"}
	}
	runnerImage := strings.TrimSpace(app.K8sRunnerImage)
	if runnerImage == "" {
		return pipeline.Result{Success: false, Log: "k8s runner image is required"}
	}

	jobName := fmt.Sprintf("noppflow-run-%d", runID)
	secretName := jobName + "-ssh"
	script := buildK8sJobScript(app)
	if strings.TrimSpace(script) == "" {
		return pipeline.Result{Success: false, Log: "empty k8s job script"}
	}

	secretYAML := buildK8sRunSecretYAML(namespace, secretName, privateKey)
	if err := kubectlApplyYAML(secretYAML); err != nil {
		return pipeline.Result{Success: false, Log: fmt.Sprintf("failed to create ssh secret: %v", err)}
	}
	defer func() { _ = kubectlDeleteResource(namespace, "secret", secretName) }()

	jobYAML := buildK8sRunJobYAML(namespace, jobName, serviceAccount, runnerImage, secretName, script)
	if err := kubectlApplyYAML(jobYAML); err != nil {
		return pipeline.Result{Success: false, Log: fmt.Sprintf("failed to create job: %v", err)}
	}

	ctx, cancel := context.WithTimeout(context.Background(), k8sRunTimeout)
	defer cancel()

	lastLog := ""
	for {
		log, err := kubectlJobLogs(namespace, jobName)
		if err == nil {
			if log != lastLog {
				lastLog = log
				if onLogUpdate != nil {
					onLogUpdate(lastLog)
				}
			}
		}

		done, success, err := kubectlJobDone(namespace, jobName)
		if err == nil && done {
			if success {
				return pipeline.Result{Success: true, Log: lastLog}
			}
			return pipeline.Result{Success: false, Log: lastLog}
		}

		select {
		case <-ctx.Done():
			if lastLog == "" {
				lastLog = "k8s job timed out"
			} else {
				lastLog += "\n\nk8s job timed out"
			}
			return pipeline.Result{Success: false, Log: lastLog}
		case <-time.After(2 * time.Second):
		}
	}
}

func kubectlApplyYAML(yamlBody string) error {
	cmd := exec.Command("kubectl", "apply", "-f", "-")
	cmd.Stdin = strings.NewReader(yamlBody)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		msg := strings.TrimSpace(stderr.String())
		if msg == "" {
			return err
		}
		return fmt.Errorf("%w: %s", err, msg)
	}
	return nil
}

func kubectlDeleteResource(namespace, kind, name string) error {
	cmd := exec.Command("kubectl", "-n", namespace, "delete", kind, name, "--ignore-not-found=true")
	return cmd.Run()
}

func kubectlOutput(args ...string) (string, error) {
	cmd := exec.Command("kubectl", args...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "", fmt.Errorf("kubectl %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
	}
	return strings.TrimSpace(string(out)), nil
}

func kubectlJobDone(namespace, jobName string) (done bool, success bool, err error) {
	succeeded, err := kubectlOutput("-n", namespace, "get", "job", jobName, "-o", "jsonpath={.status.succeeded}")
	if err != nil {
		return false, false, err
	}
	if succeeded != "" && succeeded != "0" {
		return true, true, nil
	}
	failed, err := kubectlOutput("-n", namespace, "get", "job", jobName, "-o", "jsonpath={.status.failed}")
	if err != nil {
		return false, false, err
	}
	if failed != "" && failed != "0" {
		return true, false, nil
	}
	return false, false, nil
}

func kubectlJobLogs(namespace, jobName string) (string, error) {
	podName, err := kubectlOutput("-n", namespace, "get", "pods", "-l", "job-name="+jobName, "-o", "jsonpath={.items[0].metadata.name}")
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(podName) == "" {
		return "", fmt.Errorf("pod not ready")
	}
	return kubectlOutput("-n", namespace, "logs", podName, "--tail=-1")
}

func buildK8sRunSecretYAML(namespace, secretName, privateKey string) string {
	encoded := base64.StdEncoding.EncodeToString([]byte(privateKey))
	return fmt.Sprintf(`apiVersion: v1
kind: Secret
metadata:
  name: %s
  namespace: %s
type: Opaque
data:
  id_key: %s
`, secretName, namespace, encoded)
}

func buildK8sRunJobYAML(namespace, jobName, serviceAccount, image, secretName, script string) string {
	return fmt.Sprintf(`apiVersion: batch/v1
kind: Job
metadata:
  name: %s
  namespace: %s
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    metadata:
      labels:
        app: noppflow-runner
    spec:
      restartPolicy: Never
      serviceAccountName: %s
      containers:
        - name: runner
          image: %s
          imagePullPolicy: IfNotPresent
          command:
            - /bin/sh
            - -c
            - |
%s
          volumeMounts:
            - name: ssh-key
              mountPath: /var/run/noppflow-ssh
              readOnly: true
      volumes:
        - name: ssh-key
          secret:
            secretName: %s
`, jobName, namespace, serviceAccount, image, indentYAMLBlock(script, 14), secretName)
}

func buildK8sJobScript(app config.App) string {
	steps := app.EffectiveSteps()
	lines := []string{
		"set -eu",
		"mkdir -p /workspace",
		"cd /workspace",
		fmt.Sprintf("export GIT_SSH_COMMAND=%s", shellQuote("ssh -i /var/run/noppflow-ssh/id_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new")),
		fmt.Sprintf("git clone --branch %s --single-branch %s repo", shellQuote(app.Branch), shellQuote(app.Repo)),
		"cd repo",
	}
	for _, step := range steps {
		lines = append(lines, fmt.Sprintf("echo %s", shellQuote("=== Step: "+step.Name+" ===")))
		switch step.Kind() {
		case "cmd":
			lines = append(lines, fmt.Sprintf("sh -c %s", shellQuote(step.Cmd)))
		case "file":
			lines = append(lines, fmt.Sprintf("sh %s", shellQuote(step.File)))
		case "script":
			lines = append(lines, fmt.Sprintf("printf %%s %s | sh", shellQuote(step.Script)))
		case "k8s_deploy":
			if app.DeployMode == "kubectl" {
				lines = append(lines, fmt.Sprintf("kubectl -n %s apply -f %s", shellQuote(app.K8sNamespace), shellQuote(app.DeployManifestPath)))
			} else if app.DeployMode == "helm" {
				helmCmd := fmt.Sprintf("helm upgrade --install %s %s -n %s", shellQuote(app.ID), shellQuote(app.HelmChart), shellQuote(app.K8sNamespace))
				if strings.TrimSpace(app.HelmValuesPath) != "" {
					helmCmd += fmt.Sprintf(" -f %s", shellQuote(app.HelmValuesPath))
				}
				lines = append(lines, helmCmd)
			}
		}
		lines = append(lines, fmt.Sprintf("echo %s", shellQuote(step.Name+" step OK")))
		if step.SleepSec > 0 {
			lines = append(lines, fmt.Sprintf("sleep %d", step.SleepSec))
		}
	}
	lines = append(lines, "echo 'pipeline completed successfully'")
	return strings.Join(lines, "\n")
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func indentYAMLBlock(s string, spaces int) string {
	prefix := strings.Repeat(" ", spaces)
	lines := strings.Split(s, "\n")
	for i := range lines {
		lines[i] = prefix + lines[i]
	}
	return strings.Join(lines, "\n")
}
