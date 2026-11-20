// scan.go -- Scanner.Go's reader: Go's own parser (go/parser, go/ast from the standard library), run with
// `go run` from this file's directory (no module, nothing fetched) over the project's files, one JSON line
// per file on stdout. Nothing of the project is compiled or written.
//
//	go run scan.go <root> <relative path>...
//
// Per file: {"path", "error" (the parser's first error, or ""), "package" (the package clause's name),
// "imports": [{"path", "name" (the alias, or "")}], "defs": [...]}. A def is a top-level function or a
// method: {"name" (`F`, or `T.M` for a method of T), "line", "hash" (of its text), "exported", "calls" (the
// calls in its body as written when the called expression is a chain of names: `f`, `pkg.F`, `r.M`, `a.b.C`),
// "recv" (the receiver's variable, "" for a function)}. Names are resolved by the caller. `init` and `_`
// functions are not defs.
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

type imp struct {
	Path string `json:"path"`
	Name string `json:"name"`
}

type def struct {
	Name     string   `json:"name"`
	Line     int      `json:"line"`
	Hash     string   `json:"hash"`
	Exported bool     `json:"exported"`
	Calls    []string `json:"calls"`
	Recv     string   `json:"recv"`
}

type file struct {
	Path    string `json:"path"`
	Error   string `json:"error"`
	Package string `json:"package"`
	Imports []imp  `json:"imports"`
	Defs    []def  `json:"defs"`
}

// `a`, `a.b.c` as text when the expression is a chain of names
func chain(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.Ident:
		return x.Name
	case *ast.SelectorExpr:
		if q := chain(x.X); q != "" {
			return q + "." + x.Sel.Name
		}
	case *ast.IndexExpr: // a generic function instantiated: f[int](…)
		return chain(x.X)
	case *ast.IndexListExpr:
		return chain(x.X)
	}
	return ""
}

// the receiver's type name: `T` for `(t T)`, `(t *T)`, `(t *T[K, V])`
func recvType(e ast.Expr) string {
	switch x := e.(type) {
	case *ast.StarExpr:
		return recvType(x.X)
	case *ast.Ident:
		return x.Name
	case *ast.IndexExpr:
		return recvType(x.X)
	case *ast.IndexListExpr:
		return recvType(x.X)
	case *ast.ParenExpr:
		return recvType(x.X)
	}
	return ""
}

func scanFile(root, rel string) file {
	out := file{Path: rel, Imports: []imp{}, Defs: []def{}}
	src, err := os.ReadFile(filepath.Join(root, rel))
	if err != nil {
		out.Error = err.Error()
		return out
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, rel, src, parser.SkipObjectResolution)
	if err != nil {
		out.Error = err.Error()
		return out
	}
	out.Package = f.Name.Name
	for _, i := range f.Imports {
		p, _ := strconv.Unquote(i.Path.Value)
		name := ""
		if i.Name != nil {
			name = i.Name.Name
		}
		out.Imports = append(out.Imports, imp{Path: p, Name: name})
	}
	for _, d := range f.Decls {
		fd, ok := d.(*ast.FuncDecl)
		if !ok || fd.Name.Name == "init" || fd.Name.Name == "_" {
			continue
		}
		name, recv := fd.Name.Name, ""
		if fd.Recv != nil && len(fd.Recv.List) > 0 {
			t := recvType(fd.Recv.List[0].Type)
			if t == "" {
				continue
			}
			name = t + "." + name
			if len(fd.Recv.List[0].Names) > 0 {
				recv = fd.Recv.List[0].Names[0].Name
			}
		}
		calls := []string{}
		seen := map[string]bool{}
		if fd.Body != nil {
			ast.Inspect(fd.Body, func(n ast.Node) bool {
				if c, ok := n.(*ast.CallExpr); ok {
					if s := chain(c.Fun); s != "" && !seen[s] {
						seen[s] = true
						calls = append(calls, s)
					}
				}
				return true
			})
		}
		start, end := fset.Position(fd.Pos()).Offset, fset.Position(fd.End()).Offset
		sum := sha256.Sum256(src[start:end])
		out.Defs = append(out.Defs, def{
			Name:     name,
			Line:     fset.Position(fd.Pos()).Line,
			Hash:     hex.EncodeToString(sum[:]),
			Exported: ast.IsExported(fd.Name.Name),
			Calls:    calls,
			Recv:     recv,
		})
	}
	return out
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: go run scan.go <root> <relative path>...")
		os.Exit(2)
	}
	root := os.Args[1]
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	for _, rel := range os.Args[2:] {
		f := scanFile(root, rel)
		if f.Error != "" {
			f.Error = strings.TrimSpace(f.Error)
		}
		enc.Encode(f)
	}
}
