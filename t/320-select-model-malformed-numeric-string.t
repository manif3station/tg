use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Transcribe;

# TGT-320 (found via a live JOB-003 hourly bug hunt, 2026-09-21):
# select_model's own duration-validation regex, /^\s*[\d.]+\s*$/, only
# checks the character class (digits and dots), not that the string is
# a structurally valid single decimal number. A string built entirely
# of digits/dots but not a real number - '1.2.3' (two decimal points),
# or '...' (no digits at all) - passes this check and is then used in a
# numeric comparison ($duration > 0 / <=), which Perl evaluates by
# numifying leniently (stopping at the first invalid character) while
# raising a bare "Argument ... isn't numeric" warning straight to
# STDERR - the same unclassified-raw-output-leak class this project has
# fixed repeatedly elsewhere (TGT-181/183/186/195/293/306/316), just via
# a different code path. This must be treated exactly like any other
# unparseable duration (silently fall back to 'medium', zero warnings),
# not like a "successfully parsed" value.

my @warnings;
local $SIG{__WARN__} = sub { push @warnings, $_[0] };

is( D2TG::Transcribe::select_model('1.2.3'), 'medium',
    "select_model('1.2.3') (two decimal points - not a real number) falls back to medium" );
is( D2TG::Transcribe::select_model('...'), 'medium',
    "select_model('...') (no digits at all) falls back to medium" );

is( scalar(@warnings), 0,
    'zero Perl warnings emitted for either malformed-but-character-class-matching input' )
  or diag( "captured warnings: @warnings" );

# select_model and _probe_duration shared the identical flawed regex,
# so the fix also extracted a single shared _looks_like_duration($str)
# helper both now call - matching TGT-279/313/314/318's own precedent
# for a pure-extraction refactor: a can()-based structural check.
ok( D2TG::Transcribe->can('_looks_like_duration'),
    'D2TG::Transcribe::_looks_like_duration exists - the shared helper collapsing both duration-validation call sites' );

done_testing();
