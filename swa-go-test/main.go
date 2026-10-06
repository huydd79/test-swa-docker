// swa-go-test: the workload gets a JWT-SVID via the SPIFFE Workload API (SWA Agent) -> exchanges it for a Secrets Manager token -> reads secrets.
// This binary is the process that connects to the socket, so the node group policy can pin it with unix.path + unix.sha256.
package main

import (
	"context"
	"encoding/base64"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/svid/jwtsvid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
)

// version: change it here (or build.sh VERSION=x.y) -> the binary hash changes -> the sha256 policy blocks it.
var version = "1.0"

func main() {
	fmt.Printf("=== swa-go-test version %s (SWA JWT-SVID -> Secrets Manager) ===\n", version)
	socket := flag.String("socket", "unix:///run/swa-agent/api.sock", "SPIFFE Workload API socket")
	smURL := flag.String("sm", os.Getenv("SM_URL"), "Secrets Manager API base, e.g. https://<tenant>.secretsmgr.cyberark.cloud/api (default: $SM_URL)")
	authnID := flag.String("authn", os.Getenv("AUTHN"), "authn-jwt service id, e.g. swa-prod (default: $AUTHN)")
	show := flag.Bool("show", false, "print secret values in full (masked by default)")
	flag.Parse()
	if *authnID == "" {
		fail("authenticator not set: use -authn <service-id> or AUTHN")
	}
	if *smURL == "" {
		fail("Secrets Manager URL not set: use -sm https://<tenant>.secretsmgr.cyberark.cloud/api or SM_URL")
	}
	vars := flag.Args()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	// 1. JWT-SVID audience conjur
	svid, err := workloadapi.FetchJWTSVID(ctx, jwtsvid.Params{Audience: "conjur"}, workloadapi.WithAddr(*socket))
	if err != nil {
		fail("fetch JWT-SVID: %v", err)
	}
	sid := svid.ID.String()
	fmt.Println("JWT-SVID sub:", sid, "exp:", svid.Expiry.Format(time.RFC3339))

	// 2. authn-jwt host-in-URL: host/data/swa/trust-domains/<td>/workloads/<spiffe-id>
	host := fmt.Sprintf("host/data/swa/trust-domains/%s/workloads/%s", svid.ID.TrustDomain().Name(), sid)
	authURL := fmt.Sprintf("%s/authn-jwt/%s/conjur/%s/authenticate", *smURL, *authnID, url.PathEscape(host))
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, authURL, strings.NewReader(url.Values{"jwt": {svid.Marshal()}}.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	raw, code := do(req)
	if code != http.StatusOK {
		fail("authenticate HTTP %d", code)
	}
	token := base64.StdEncoding.EncodeToString(raw)
	fmt.Printf("Access token: OK (%d bytes)\n", len(token))

	// 3. Read secrets
	for _, v := range vars {
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, *smURL+"/secrets/conjur/variable/"+url.PathEscape(v), nil)
		req.Header.Set("Authorization", fmt.Sprintf("Token token=%q", token))
		val, code := do(req)
		switch {
		case code != http.StatusOK:
			fmt.Printf("%s -> HTTP %d\n", v, code)
		case *show:
			fmt.Printf("%s = %s\n", v, val)
		default:
			fmt.Printf("%s = %s***** (%d chars)\n", v, val[:min(2, len(val))], len(val))
		}
	}
}

func do(req *http.Request) ([]byte, int) {
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fail("%s %s: %v", req.Method, req.URL.Path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	return b, resp.StatusCode
}

func fail(f string, a ...any) {
	fmt.Fprintf(os.Stderr, "ERROR: "+f+"\n", a...)
	os.Exit(1)
}
