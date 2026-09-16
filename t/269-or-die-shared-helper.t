use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

use lib "$Bin/../lib";
require D2TG::OrDie;

# TGT-269 (found via a scheduled JOB-004 improvement hunt):
# extract_bot_flag_or_die/extract_db_flag_or_die/resolve_alias_dir_or_die/
# require_existing_base_dir_or_die each independently hand-rolled the
# identical eval/print-STDERR/exit(1) wrapper idiom - only the wrapped
# function and its return shape (scalar vs list) differed. Extracted
# into D2TG::OrDie::or_die, a wantarray-aware higher-order helper with
# zero use-dependencies on D2TG::Config/D2TG::Config::Paths/D2TG::Reply
# (a leaf module, deliberately, to avoid the circular-use trap: Config
# already uses Config::Paths, so Config::Paths cannot use Config back).

can_ok( 'D2TG::OrDie', 'or_die' );

# List-context success: full list returned.
{
    my @result = D2TG::OrDie::or_die( sub { return ( 'a', 'b', 'c' ) } );
    is_deeply( \@result, [ 'a', 'b', 'c' ], 'list-context success returns the full list' );
}

# Scalar-context success: just the first value.
{
    my $result = D2TG::OrDie::or_die( sub { return 'solo' } );
    is( $result, 'solo', 'scalar-context success returns the single value' );
}

# Args are passed through to the wrapped coderef.
{
    my @result = D2TG::OrDie::or_die( sub { return ( 'got', @_ ) }, 'x', 'y' );
    is_deeply( \@result, [ 'got', 'x', 'y' ], 'extra args are passed through to the wrapped coderef' );
}

# Failure: prints the die message to STDERR and exits 1 - exercised via
# a real subprocess (backtick + system perl -Ilib), since or_die()
# itself calls exit().
{
    my $lib_dir = File::Spec->catdir( $Bin, '..', 'lib' );
    my $out     = `"$^X" -I"$lib_dir" -MD2TG::OrDie -e 'D2TG::OrDie::or_die(sub { die "boom requires a value\\n" })' 2>&1`;
    my $rc      = $? >> 8;

    is( $rc, 1, 'a failing wrapped coderef makes or_die() exit 1' );
    like( $out, qr/boom requires a value/, 'the die message is printed to STDERR' );
}

done_testing();
