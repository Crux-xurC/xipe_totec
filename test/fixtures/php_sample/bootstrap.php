<?php
// a global helper, declared once even when included twice
if (!function_exists('helper')) {
    function helper(): int { return App\Util\twice(1); }
}

echo "top level: never run by the scan\n";
