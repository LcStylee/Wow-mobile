// Package phones is the server's view of the phone-model table
// (docs/PHONE_FRAME.md §2). The data lives in phones_gen.go, generated from
// phones/phones.json by tools/genphones.js; this file holds the hand-written
// lookups around it.
package phones

//go:generate node ../../../tools/genphones.js

import "strings"

// Phone is one selectable phone model. StreamW/StreamH are the frame's aspect
// as an integer ratio (the phone's usable portrait area below the OS insets
// and above the client's control deck), derived once by the generator.
type Phone struct {
	ID          string
	Brand       string
	Model       string
	Year        int
	PhysW       int
	PhysH       int
	DPRMilli    int // devicePixelRatio x 1000
	InsetTop    int
	InsetBottom int
	Popularity  int // 1..N = rank in the starting list, 0 = extra
	StreamW     int
	StreamH     int
}

// Name is the display name ("Apple iPhone 17").
func (p Phone) Name() string {
	if p.Brand == "" || strings.HasPrefix(p.Model, p.Brand) {
		return p.Model
	}
	return p.Brand + " " + p.Model
}

// Vector is one shared frame-placement contract vector.
type Vector struct {
	Phone            string
	ClientW, ClientH int
	X, Y, W, H       int
	EncW, EncH       int
}

// ByID returns the phone with the given id.
func ByID(id string) (Phone, bool) {
	for _, p := range All {
		if p.ID == id {
			return p, true
		}
	}
	return Phone{}, false
}

// Default is the fallback phone (PHONE_FRAME.md §5's last ladder rung).
func Default() Phone {
	p, _ := ByID(DefaultID)
	return p
}

// Search returns the phones whose "brand model" contains every
// whitespace-separated term of q (case-insensitive), in selector order. An
// empty query returns the whole table.
func Search(q string) []Phone {
	terms := strings.Fields(strings.ToLower(q))
	var out []Phone
	for _, p := range All {
		hay := strings.ToLower(p.Brand + " " + p.Model + " " + p.ID)
		match := true
		for _, t := range terms {
			if !strings.Contains(hay, t) {
				match = false
				break
			}
		}
		if match {
			out = append(out, p)
		}
	}
	return out
}
