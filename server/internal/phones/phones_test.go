package phones

import (
	"encoding/json"
	"os"
	"os/exec"
	"testing"
)

func TestTableInvariants(t *testing.T) {
	if _, ok := ByID(DefaultID); !ok {
		t.Fatalf("default phone %q missing", DefaultID)
	}
	ranked := 0
	for i, p := range All {
		if p.StreamW <= 0 || p.StreamH <= p.StreamW {
			t.Errorf("%s: stream %dx%d is not portrait", p.ID, p.StreamW, p.StreamH)
		}
		if p.Popularity > 0 {
			ranked++
			if p.Popularity != i+1 {
				t.Errorf("%s: popularity %d at position %d — ranked phones must lead the table in rank order", p.ID, p.Popularity, i)
			}
		}
	}
	if ranked != 20 {
		t.Errorf("starting list has %d ranked phones, want the 20 most used", ranked)
	}
}

func TestSearch(t *testing.T) {
	if got := Search(""); len(got) != len(All) {
		t.Fatalf("empty query: %d results, want %d", len(got), len(All))
	}
	got := Search("galaxy ULTRA")
	if len(got) == 0 {
		t.Fatal("no Galaxy Ultra found")
	}
	for _, p := range got {
		if p.Brand != "Samsung" {
			t.Errorf("unexpected match %s", p.ID)
		}
	}
	if got := Search("no such phone"); len(got) != 0 {
		t.Errorf("nonsense query matched %d phones", len(got))
	}
}

// The generated Go vectors must equal the shared JSON file every other
// component reads.
func TestVectorsMatchJSON(t *testing.T) {
	raw, err := os.ReadFile("../../../phones/contract_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var doc struct {
		RingPx  int `json:"ringPx"`
		Vectors []struct {
			Phone                  string
			ClientW, ClientH       int
			X, Y, W, H, EncW, EncH int
		} `json:"vectors"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		t.Fatal(err)
	}
	if doc.RingPx != RingPx {
		t.Fatalf("ringPx %d, want %d", doc.RingPx, RingPx)
	}
	if len(doc.Vectors) != len(ContractVectors) {
		t.Fatalf("%d JSON vectors, %d Go vectors", len(doc.Vectors), len(ContractVectors))
	}
	for i, v := range doc.Vectors {
		g := ContractVectors[i]
		if v.Phone != g.Phone || v.ClientW != g.ClientW || v.ClientH != g.ClientH || v.X != g.X || v.Y != g.Y ||
			v.W != g.W || v.H != g.H || v.EncW != g.EncW || v.EncH != g.EncH {
			t.Errorf("vector %d differs: json %+v go %+v", i, v, g)
		}
	}
}

// Generated files must be fresh (skipped where node is unavailable; CI also
// runs the generator's own --check).
func TestGeneratedFresh(t *testing.T) {
	node, err := exec.LookPath("node")
	if err != nil {
		t.Skip("node not installed")
	}
	out, err := exec.Command(node, "../../../tools/genphones.js", "--check").CombinedOutput()
	if err != nil {
		t.Fatalf("generated phone files are stale: %s", out)
	}
}
