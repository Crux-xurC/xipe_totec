<?php
declare(strict_types=1);

namespace App;

/** Static functions and an instance method. */
final class Calc
{
    public static function add(int $a, int $b): int { return $a + $b; }

    public static function add3(int $a, int $b, int $c): int { return self::add(self::add($a, $b), $c); }

    private static function secret(int $x): int { return $x; }

    protected function guarded(): int { return 1; }

    public function step(int $by): int { return $this->guarded() + $by + static::secret(1); }

    public static function label(int $x): string
    {
        $s = "value {$x} and ${x} }";
        $t = <<<EOT
            heredoc { with } braces {$x}
            EOT;
        $f = fn($y) => self::add($y, 1);
        $g = function ($y) use ($x) { return Calc::add($x, $y); };
        return $s . $t . $f(1) . $g(2) . strlen(Calc::class);
    }
}
