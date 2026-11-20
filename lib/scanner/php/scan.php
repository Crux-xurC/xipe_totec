<?php
// scan.php -- Scanner.Php's reader: PHP's own lexer (token_get_all with TOKEN_PARSE, which runs PHP's parser
// to check the file), run with `php` over the project's files, one JSON line per file on stdout. Nothing of
// the project is loaded or run.
//
//     php scan.php <root> <relative path>...
//
// Per file: {"path", "error" (the parser's message, or null), "defs": [...]}. A def is a named function or a
// method of a class, interface, trait or enum: {"module" (the class's full name, `App\Geo\Shapes`, or the
// namespace for a function, `App\Util`; `\` for the global one), "name", "line", "hash" (of its text),
// "public" (a function, or a method not `private` / `protected`), "calls" (the calls in its body: `f`,
// `A\f`, `\A\f`, `X::m`, `self::m`, `static::m`, `parent::m`, `$this->m`), "namespace", "uses" (class
// aliases -> full names), "functions" (function aliases -> full names), "class", "parent" (the class it
// extends, as written)}. Names are resolved by the caller. Closures and arrow functions are not defs.

function significant(array $tokens, int $i, int $step): int {
    for ($j = $i + $step; $j >= 0 && $j < count($tokens); $j += $step) {
        $t = $tokens[$j];
        if (is_array($t) && in_array($t[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) continue;
        return $j;
    }
    return -1;
}

function kind($t) { return is_array($t) ? $t[0] : $t; }
function text($t): string { return is_array($t) ? $t[1] : $t; }

const NAMES = [T_STRING, T_NAME_QUALIFIED, T_NAME_FULLY_QUALIFIED, T_NAME_RELATIVE];

function scanFile(string $root, string $rel): array {
    $src = file_get_contents($root . '/' . $rel);
    if ($src === false) return ['path' => $rel, 'error' => 'not readable', 'defs' => []];
    try {
        $tokens = token_get_all($src, TOKEN_PARSE);
    } catch (\Throwable $e) {
        return ['path' => $rel, 'error' => $rel . ':' . $e->getLine() . ': ' . $e->getMessage(), 'defs' => []];
    }
    // byte offsets of the tokens, for a definition's text
    $offsets = [];
    $off = 0;
    foreach ($tokens as $k => $t) { $offsets[$k] = $off; $off += strlen(text($t)); }

    $defs = [];
    $namespace = '';
    $uses = []; $functions = [];
    $depth = 0;
    // open contexts: ['class', name, parent, depth] or ['function', index of the def, depth]
    $stack = [];
    $pendingClass = null;     // a class header seen, its body's `{` not yet
    $pendingFunction = null;  // a named function's header seen, its body's `{` (or `;`) not yet
    $nsBraced = false;

    $n = count($tokens);
    for ($i = 0; $i < $n; $i++) {
        $t = $tokens[$i];
        $k = kind($t);
        $inClass = $stack && end($stack)[0] === 'class';
        $inFunction = false;
        foreach ($stack as $c) if ($c[0] === 'function') $inFunction = true;

        if ($k === T_NAMESPACE && !$inFunction && !$inClass) {
            $j = significant($tokens, $i, 1);
            $name = '';
            while ($j >= 0 && in_array(kind($tokens[$j]), NAMES, true)) { $name .= text($tokens[$j]); $j = significant($tokens, $j, 1); }
            if ($j >= 0 && in_array(kind($tokens[$j]), [';', '{'], true)) {
                $namespace = ltrim($name, '\\');
                $uses = []; $functions = [];
            }
            continue;
        }

        if ($k === T_USE && !$inFunction && !$inClass) {
            // use A\B; use A\B as C; use function A\f; use A\{B, C as D};
            $j = significant($tokens, $i, 1);
            $what = 'class';
            if ($j >= 0 && kind($tokens[$j]) === T_FUNCTION) { $what = 'function'; $j = significant($tokens, $j, 1); }
            elseif ($j >= 0 && kind($tokens[$j]) === T_CONST) { $what = 'const'; $j = significant($tokens, $j, 1); }
            $prefix = '';
            $items = [];
            $cur = ''; $alias = null; $grouped = false;
            for (; $j >= 0 && $j < $n; $j = significant($tokens, $j, 1)) {
                $tk = $tokens[$j]; $kk = kind($tk);
                if ($kk === ';') break;
                if ($kk === T_NS_SEPARATOR || $kk === '{') {
                    if ($kk === '{') { $prefix = $cur; $cur = ''; $grouped = true; }
                    else { $cur .= '\\'; }
                    continue;
                }
                if ($kk === T_AS) { $j = significant($tokens, $j, 1); $alias = text($tokens[$j]); continue; }
                if ($kk === ',' || $kk === '}') { if ($cur !== '') $items[] = [$cur, $alias]; $cur = ''; $alias = null; continue; }
                if (in_array($kk, NAMES, true)) $cur .= text($tk);
            }
            if ($cur !== '') $items[] = [$cur, $alias];
            foreach ($items as [$name, $al]) {
                $full = ltrim(($grouped ? rtrim($prefix, '\\') . '\\' : '') . $name, '\\');
                $short = $al ?? substr($full, (int) strrpos('\\' . $full, '\\'));
                if ($what === 'class') $uses[strtolower($short)] = $full;
                elseif ($what === 'function') $functions[strtolower($short)] = $full;
            }
            $i = $j;
            continue;
        }

        if (in_array($k, [T_CLASS, T_INTERFACE, T_TRAIT, T_ENUM], true)) {
            $p = significant($tokens, $i, -1);
            $pk = $p >= 0 ? kind($tokens[$p]) : null;
            $j = significant($tokens, $i, 1);
            // `Foo::class`, `new class`, an enum's `case`: not a declaration
            if ($pk !== T_DOUBLE_COLON && $pk !== T_NEW && $j >= 0 && kind($tokens[$j]) === T_STRING) {
                $name = text($tokens[$j]);
                $parent = null;
                for ($m = $j; $m < $n && kind($tokens[$m]) !== '{'; $m++) {
                    if (kind($tokens[$m]) === T_EXTENDS) {
                        $q = significant($tokens, $m, 1);
                        $parent = text($tokens[$q]);
                    }
                }
                $pendingClass = [ltrim(($namespace === '' ? '' : $namespace . '\\') . $name, '\\'), $parent];
            }
            continue;
        }

        if ($k === T_FUNCTION) {
            $j = significant($tokens, $i, 1);
            if ($j >= 0 && kind($tokens[$j]) === '&') $j = significant($tokens, $j, 1);
            if ($j >= 0 && kind($tokens[$j]) === T_STRING && !$inFunction) {
                // a method's modifiers before `function`
                $private = false;
                for ($p = significant($tokens, $i, -1); $p >= 0 && in_array(kind($tokens[$p]), [T_PUBLIC, T_PRIVATE, T_PROTECTED, T_STATIC, T_ABSTRACT, T_FINAL, T_READONLY], true); $p = significant($tokens, $p, -1)) {
                    if (in_array(kind($tokens[$p]), [T_PRIVATE, T_PROTECTED], true)) $private = true;
                }
                $class = $inClass ? end($stack) : null;
                $start = $i;
                while (($q = significant($tokens, $start, -1)) >= 0 && in_array(kind($tokens[$q]), [T_PUBLIC, T_PRIVATE, T_PROTECTED, T_STATIC, T_ABSTRACT, T_FINAL, T_READONLY, T_ATTRIBUTE], true)) $start = $q;
                $defs[] = [
                    'module' => $class ? $class[1] : ($namespace === '' ? '\\' : $namespace),
                    'name' => text($tokens[$j]),
                    'line' => is_array($tokens[$start]) ? $tokens[$start][2] : $tokens[$j][2],
                    'start' => $offsets[$start],
                    'public' => !$private,
                    'calls' => [],
                    'namespace' => $namespace,
                    'uses' => (object) $uses,
                    'functions' => (object) $functions,
                    'class' => $class ? $class[1] : null,
                    'parent' => $class ? $class[2] : null,
                ];
                $pendingFunction = count($defs) - 1;
            }
            continue;
        }

        if ($k === ';' && $pendingFunction !== null && !$inFunction) {
            // an abstract or interface method: no body
            $defs[$pendingFunction]['end'] = $offsets[$i] + 1;
            $pendingFunction = null;
            continue;
        }

        if ($k === '{' || $k === T_CURLY_OPEN || $k === T_DOLLAR_OPEN_CURLY_BRACES) {
            $depth++;
            if ($k === '{' && $pendingClass !== null) {
                $stack[] = ['class', $pendingClass[0], $pendingClass[1], $depth];
                $pendingClass = null;
            } elseif ($k === '{' && $pendingFunction !== null) {
                $stack[] = ['function', $pendingFunction, $depth];
                $pendingFunction = null;
            }
            continue;
        }

        if ($k === '}') {
            if ($stack && end($stack)[count(end($stack)) - 1] === $depth) {
                $c = array_pop($stack);
                if ($c[0] === 'function') $defs[$c[1]]['end'] = $offsets[$i] + 1;
            }
            $depth--;
            continue;
        }

        // calls, inside the innermost named function
        if ($inFunction && in_array($k, NAMES, true) || $inFunction && $k === T_STATIC || $inFunction && $k === T_VARIABLE && text($t) === '$this') {
            $owner = null;
            foreach (array_reverse($stack) as $c) if ($c[0] === 'function') { $owner = $c[1]; break; }
            $j = significant($tokens, $i, 1);
            if ($j < 0) continue;
            $p = significant($tokens, $i, -1);
            $pk = $p >= 0 ? kind($tokens[$p]) : null;
            if ($k === T_VARIABLE) {
                // $this->m(
                if (in_array(kind($tokens[$j]), [T_OBJECT_OPERATOR, T_NULLSAFE_OBJECT_OPERATOR], true)) {
                    $m = significant($tokens, $j, 1);
                    $o = $m >= 0 ? significant($tokens, $m, 1) : -1;
                    if ($m >= 0 && kind($tokens[$m]) === T_STRING && $o >= 0 && kind($tokens[$o]) === '(') $defs[$owner]['calls'][] = '$this->' . text($tokens[$m]);
                }
                continue;
            }
            if (kind($tokens[$j]) === T_DOUBLE_COLON) {
                // X::m(
                $m = significant($tokens, $j, 1);
                $o = $m >= 0 ? significant($tokens, $m, 1) : -1;
                if ($m >= 0 && kind($tokens[$m]) === T_STRING && $o >= 0 && kind($tokens[$o]) === '(') $defs[$owner]['calls'][] = text($t) . '::' . text($tokens[$m]);
                continue;
            }
            if (kind($tokens[$j]) === '(' && $k !== T_STATIC && !in_array($pk, [T_OBJECT_OPERATOR, T_NULLSAFE_OBJECT_OPERATOR, T_DOUBLE_COLON, T_FUNCTION, T_NEW, T_FN], true)) {
                $defs[$owner]['calls'][] = text($t);
            }
        }
    }

    $out = [];
    foreach ($defs as $d) {
        $end = $d['end'] ?? strlen($src);
        $d['hash'] = hash('sha256', substr($src, $d['start'], $end - $d['start']));
        $d['calls'] = array_values(array_unique($d['calls']));
        unset($d['start'], $d['end']);
        $out[] = $d;
    }
    return ['path' => $rel, 'error' => null, 'defs' => $out];
}

$root = $argv[1] ?? '.';
foreach (array_slice($argv, 2) as $rel) {
    try {
        $r = scanFile($root, $rel);
    } catch (\Throwable $e) {
        $r = ['path' => $rel, 'error' => get_class($e) . ': ' . $e->getMessage(), 'defs' => []];
    }
    echo json_encode($r, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
}
