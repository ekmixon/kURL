package main

import (
	"bytes"
	"flag"
	"fmt"
	"io/ioutil"
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/pkg/errors"
	kurlscheme "github.com/replicatedhq/kurl/kurlkinds/client/kurlclientset/scheme"
	kurlv1beta1 "github.com/replicatedhq/kurl/kurlkinds/pkg/apis/cluster/v1beta1"
	serializer "k8s.io/apimachinery/pkg/runtime/serializer/json"
	"k8s.io/client-go/kubernetes/scheme"
)

func getInstallerConfigFromYaml(yamlPath string) (*kurlv1beta1.Installer, error) {
	yamlData, err := ioutil.ReadFile(yamlPath)
	if err != nil {
		return nil, errors.Wrapf(err, "failed to load file %s", yamlPath)
	}

	yamlData = bytes.TrimSpace(yamlData)
	if len(yamlData) == 0 {
		return nil, nil
	}

	decode := scheme.Codecs.UniversalDeserializer().Decode
	obj, gvk, err := decode(yamlData, nil, nil)
	if err != nil {
		return nil, errors.Wrap(err, "failed to decode installer yaml")
	}

	if gvk.Group != "cluster.kurl.sh" || gvk.Version != "v1beta1" || gvk.Kind != "Installer" {
		return nil, errors.Errorf("installer yaml contained unepxected gvk: %s/%s/%s", gvk.Group, gvk.Version, gvk.Kind)
	}

	installer := obj.(*kurlv1beta1.Installer)

	return installer, nil
}

func checkIfFlagHasValue(length int, flag string) bool {
	shouldHaveLengthTwo := []string{
		"cert-key",
		"docker-rgistry-ip",
		"kubeadm-token",
		"kubeadm-token-ca-hash",
		"kubernetes-master-address",
		"kubernetes-version"}

	for _, variable := range shouldHaveLengthTwo {
		if variable == flag {
			if length != 2 {
				return false
			}
			return true
		}
	}
	return true
}

func parseBashFlags(installer *kurlv1beta1.Installer, bashFlags string) error {
	s := strings.Split(bashFlags, " ")

	for _, flag := range s {
		split := strings.Split(flag, "=")

		if !checkIfFlagHasValue(len(split), split[0]) {
			return errors.New(fmt.Sprintf("flag %s does not have a value", split[0]))
		}

		switch split[0] {

		case "airgap":
			installer.Spec.Kurl.Airgap = true
		case "cert-key":
			installer.Spec.Kubernetes.CertKey = split[1]
		case "control-plane":
			installer.Spec.Kubernetes.ControlPlane = true
		case "docker-registry-ip":
			installer.Spec.Docker.DockerRegistryIP = split[1]
		case "ha":
			installer.Spec.Kubernetes.HACluster = true
		case "kubeadm-token":
			installer.Spec.Kubernetes.KubeadmToken = split[1]
		case "kubeadm-token-ca-hash":
			installer.Spec.Kubernetes.KubeadmTokenCAHash = split[1]
		case "kubernetes-master-address":
			installer.Spec.Kubernetes.MasterAddress = split[1]
		case "kubernetes-version":
			installer.Spec.Kubernetes.Version = split[1]
		case "installer-spec-file":
			continue
		default:
			return errors.New(fmt.Sprintf("string %s is not a bash flag", split[0]))
		}
	}

	return nil
}

func mergeConfig(currentYAMLPath string, bashFlags string) error {
	currentConfig, err := getInstallerConfigFromYaml(currentYAMLPath)
	if err != nil {
		return errors.Wrap(err, "failed to load current config")
	}

	if err := parseBashFlags(currentConfig, bashFlags); err != nil {
		return errors.Wrapf(err, "failed to parse flag string %s", bashFlags)
	}

	s := serializer.NewYAMLSerializer(serializer.DefaultMetaFactory, scheme.Scheme, scheme.Scheme)

	var b bytes.Buffer
	if err := s.Encode(currentConfig, &b); err != nil {
		return errors.Wrap(err, "failed to reserialize yaml")
	}

	if err := writeSpec(currentYAMLPath, b.Bytes()); err != nil {
		return errors.Wrapf(err, "failed to write file %s", currentYAMLPath)
	}

	return nil
}

func writeSpec(filename string, spec []byte) error {
	err := os.MkdirAll(filepath.Dir(filename), 0755)
	if err != nil {
		return errors.Wrap(err, "failed to create script dir")
	}

	f, err := os.OpenFile(filename, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0644)
	if err != nil {
		return errors.Wrap(err, "failed to create script file")
	}
	defer f.Close()

	_, err = f.Write(spec)
	if err != nil {
		return errors.Wrap(err, "failed to write script file")
	}

	return nil
}

func main() {
	kurlscheme.AddToScheme(scheme.Scheme)

	currentYAMLPath := flag.String("c", "", "current yaml file")
	bashFlags := flag.String("f", "", "bash flag overwrites")

	flag.Parse()

	if *currentYAMLPath == "" || *bashFlags == "" {
		flag.PrintDefaults()
		os.Exit(-1)
	}

	if err := mergeConfig(*currentYAMLPath, *bashFlags); err != nil {
		log.Fatal(err)
	}
}
