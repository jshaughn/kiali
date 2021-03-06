package server

import (
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"fmt"
	"io/ioutil"
	"math/big"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/swift-sunshine/swscore/config"
	"github.com/swift-sunshine/swscore/config/security"
)

const (
	authorizedUsername = "theUser"
	authorizedPassword = "thePassword"
	authorizedToken    = "theToken"
)

const (
	testHostname = "127.0.0.1"
)

var tmpDir = os.TempDir()

func TestSecureComm(t *testing.T) {
	testPort, err := getFreePort(testHostname)
	if err != nil {
		t.Fatalf("Cannot get a free port to run tests on host [%v]", testHostname)
	} else {
		t.Logf("Will use free port [%v] on host [%v] for tests", testPort, testHostname)
	}

	testServerCertFile := tmpDir + "/server-test-server.cert"
	testServerKeyFile := tmpDir + "/server-test-server.key"
	testServerHostPort := fmt.Sprintf("%v:%v", testHostname, testPort)
	err = generateCertificate(t, testServerCertFile, testServerKeyFile, testServerHostPort)
	if err != nil {
		t.Fatalf("Failed to create server cert/key files: %v", err)
	}
	defer os.Remove(testServerCertFile)
	defer os.Remove(testServerKeyFile)

	testClientCertFile := tmpDir + "/server-test-client.cert"
	testClientKeyFile := tmpDir + "/server-test-client.key"
	testClientHost := testHostname
	err = generateCertificate(t, testClientCertFile, testClientKeyFile, testClientHost)
	if err != nil {
		t.Fatalf("Failed to create client cert/key files: %v", err)
	}
	defer os.Remove(testClientCertFile)
	defer os.Remove(testClientKeyFile)

	staticFile := tmpDir + "/static-file.txt"
	generateStaticFile(t, staticFile, "static content")
	defer os.Remove(staticFile)

	conf := new(config.Config)
	conf.Identity.Cert_File = testServerCertFile
	conf.Identity.Private_Key_File = testServerKeyFile
	conf.Server.Address = testHostname
	conf.Server.Port = testPort
	conf.Server.Static_Content_Root_Directory = tmpDir
	conf.Server.Credentials.Username = authorizedUsername
	conf.Server.Credentials.Password = authorizedPassword

	serverUrl := fmt.Sprintf("https://%v", testServerHostPort)
	consoleUrl := serverUrl + "/console"
	apiUrl := serverUrl + "/api"

	server := NewServer(conf)
	server.Start()
	t.Logf("Started test http server: %v", serverUrl)
	defer func() {
		server.Stop()
		t.Logf("Stopped test server: %v", serverUrl)
	}()

	// the client
	httpConfig := HttpClientConfig{
		Identity: &security.Identity{
			Cert_File:        testClientCertFile,
			Private_Key_File: testClientKeyFile,
		},
		TLSConfig: &tls.Config{
			InsecureSkipVerify: true,
		},
	}
	httpClient, err := httpConfig.BuildHttpClient()
	if err != nil {
		t.Fatalf("Failed to create http client")
	}

	// the good basic credentials
	basicCredentials := &security.Credentials{
		Username: authorizedUsername,
		Password: authorizedPassword,
	}

	// bad basic credentials
	badBasicCredentials := &security.Credentials{
		Username: "invalid username",
		Password: "invalid password",
	}

	// no credentials
	noCredentials := &security.Credentials{}

	// wait for our test http server to come up
	checkHttpReady(httpClient, serverUrl)

	// TEST WITH AN AUTHORIZED USER

	if _, err = getRequestResults(t, httpClient, consoleUrl, basicCredentials); err != nil {
		t.Fatalf("Failed: Basic Auth Console URL: %v", err)
	}

	if _, err = getRequestResults(t, httpClient, apiUrl, basicCredentials); err != nil {
		t.Fatalf("Failed: Basic Auth API URL: %v", err)
	}

	// TEST WITH AN INVALID USER

	if _, err = getRequestResults(t, httpClient, consoleUrl, badBasicCredentials); err == nil {
		t.Fatalf("Failed: Basic Auth Console URL should have failed")
	}

	if _, err = getRequestResults(t, httpClient, apiUrl, badBasicCredentials); err == nil {
		t.Fatalf("Failed: Basic Auth API URL should have failed")
	}

	// TEST WITH NO USER

	if _, err = getRequestResults(t, httpClient, consoleUrl, noCredentials); err == nil {
		t.Fatalf("Failed: Basic Auth Console URL should have failed with no credentials: %v", err)
	}

	if _, err = getRequestResults(t, httpClient, apiUrl, noCredentials); err == nil {
		t.Fatalf("Failed: Basic Auth API URL should have failed with with no credentials")
	}
}

func getRequestResults(t *testing.T, httpClient *http.Client, url string, credentials *security.Credentials) (string, error) {
	r, err := http.NewRequest("GET", url, nil)
	if err != nil {
		t.Fatal(err)
		return "", err
	}
	if headerName, headerValue, err := credentials.GetHttpAuthHeader(); err != nil {
		t.Fatal(err)
		return "", err
	} else if headerName != "" {
		r.Header.Add(headerName, headerValue)
	}

	if resp, err := httpClient.Do(r); err != nil {
		return "", err
	} else {
		defer resp.Body.Close()
		if resp.StatusCode == http.StatusOK {
			bodyBytes, err2 := ioutil.ReadAll(resp.Body)
			if err2 != nil {
				return "", err2
			}
			bodyString := string(bodyBytes)
			return bodyString, nil
		} else {
			return "", fmt.Errorf("Bad status: %v", resp.StatusCode)
		}
	}
}

func generateStaticFile(t *testing.T, filename string, content string) {
	file, err := os.Create(filename)
	if err != nil {
		t.Fatalf("Cannot create file [%v]: %v", filename, err)
	}
	defer file.Close()
	fmt.Fprintf(file, content)
}

func generateCertificate(t *testing.T, certPath string, keyPath string, host string) error {
	priv, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return err
	}

	serialNumber, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}

	notBefore := time.Now()
	notAfter := notBefore.Add(365 * 24 * time.Hour)

	template := x509.Certificate{
		SerialNumber:          serialNumber,
		NotBefore:             notBefore,
		NotAfter:              notAfter,
		KeyUsage:              x509.KeyUsageKeyEncipherment | x509.KeyUsageDigitalSignature,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		Subject: pkix.Name{
			Organization: []string{"ABC Corp."},
		},
	}

	hosts := strings.Split(host, ",")
	for _, h := range hosts {
		if ip := net.ParseIP(h); ip != nil {
			template.IPAddresses = append(template.IPAddresses, ip)
		} else {
			template.DNSNames = append(template.DNSNames, h)
		}
	}

	template.IsCA = true
	template.KeyUsage |= x509.KeyUsageCertSign

	derBytes, err := x509.CreateCertificate(rand.Reader, &template, &template, &priv.PublicKey, priv)
	if err != nil {
		return err
	}

	certOut, err := os.Create(certPath)
	if err != nil {
		return err
	}
	pem.Encode(certOut, &pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	certOut.Close()

	keyOut, err := os.OpenFile(keyPath, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0600)
	if err != nil {
		return err
	}

	pemBlockForKey := &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(priv)}
	pem.Encode(keyOut, pemBlockForKey)
	keyOut.Close()

	t.Logf("Generated security data: %v|%v|%v", certPath, keyPath, host)
	return nil
}

func getFreePort(host string) (int, error) {
	addr, err := net.ResolveTCPAddr("tcp", host+":0")
	if err != nil {
		return 0, err
	}

	l, err := net.ListenTCP("tcp", addr)
	if err != nil {
		return 0, err
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port, nil
}

func checkHttpReady(httpClient *http.Client, url string) {
	for i := 0; i < 60; i++ {
		if r, err := httpClient.Get(url); err == nil {
			r.Body.Close()
			break
		} else {
			time.Sleep(time.Second)
		}
	}
}

// A generic HTTP client used to test accessing the server

type HttpClientConfig struct {
	Identity      *security.Identity
	TLSConfig     *tls.Config
	HTTPTransport *http.Transport
}

func (conf *HttpClientConfig) BuildHttpClient() (*http.Client, error) {

	// make our own copy of TLS config
	tlsConfig := &tls.Config{}
	if conf.TLSConfig != nil {
		*tlsConfig = *conf.TLSConfig
	}

	if conf.Identity != nil && conf.Identity.Cert_File != "" {
		cert, err := tls.LoadX509KeyPair(conf.Identity.Cert_File, conf.Identity.Private_Key_File)
		if err != nil {
			return nil, fmt.Errorf("Error loading the client certificates: %v", err)
		}
		tlsConfig.Certificates = append(tlsConfig.Certificates, cert)
	}

	// make our own copy of HTTP transport
	transport := &http.Transport{}
	if conf.HTTPTransport != nil {
		*transport = *conf.HTTPTransport
	}

	// make sure the transport has some things we know we need
	transport.TLSClientConfig = tlsConfig

	if transport.IdleConnTimeout == 0 {
		transport.IdleConnTimeout = time.Second * 600
	}
	if transport.ResponseHeaderTimeout == 0 {
		transport.ResponseHeaderTimeout = time.Second * 600
	}

	// build the http client
	httpClient := http.Client{Transport: transport}

	return &httpClient, nil
}
