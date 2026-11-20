<?php

namespace App\Geo;

use App\Calc;
use App\{Base, Named as HasName};
use function App\Util\twice;

class Shapes extends Base implements HasName
{
    public function area(): float { return parent::unit() * twice(2); }

    public function name(): string { return 'shapes'; }

    public static function describe(int $x): string
    {
        $anon = new class { public function hidden(): int { return 0; } };
        return Calc::label(Calc::add($x, 1)) . \App\Util\thrice($x) . static::tag();
    }

    public static function tag(): string { return 'tag'; }
}
