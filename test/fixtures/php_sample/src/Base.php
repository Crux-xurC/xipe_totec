<?php

namespace App;

abstract class Base
{
    abstract public function area(): float;

    public static function unit(): float { return 1.0; }
}

interface Named
{
    public function name(): string;
}

trait Greets
{
    public function greet(): string { return 'hi ' . $this->name(); }
}

enum Suit: string
{
    case Hearts = 'H';
    case Spades = 'S';

    public function color(): string { return $this === self::Hearts ? 'Red' : 'Black'; }
}
