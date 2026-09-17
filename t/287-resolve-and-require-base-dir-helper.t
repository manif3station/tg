use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);

use D2TG::Config;
use D2TG::Config::Paths;

# TGT-287 (found via a scheduled JOB-003/004 sweep): resolve_alias_dir_or_die
# immediately followed by require_existing_base_dir_or_die on its result was
# hand-copied, byte-for-byte, across 12 cli/*.pl scripts. This proves the new
# combined helper exists on both D2TG::Config (the public forwarder every
# cli/*.pl script actually calls) and D2TG::Config::Paths (its real home),
# and that it behaves identically to calling both steps by hand.

ok( D2TG::Config->can('resolve_and_require_base_dir_or_die'),
    'D2TG::Config owns resolve_and_require_base_dir_or_die' );
ok( D2TG::Config::Paths->can('resolve_and_require_base_dir_or_die'),
    'D2TG::Config::Paths owns resolve_and_require_base_dir_or_die' );

{
    my $dir = tempdir( CLEANUP => 1 );
    local $ENV{TIRA_HOME} = $dir;

    my $base_dir = D2TG::Config::resolve_and_require_base_dir_or_die( alias => undef );
    is( $base_dir, $dir, 'returns the same existing directory the two-step call would resolve' );
}

# The failure path (a resolved directory that does not exist) is
# deliberately NOT re-tested here: resolve_and_require_base_dir_or_die
# delegates straight to D2TG::OrDie::or_die, whose own exit(1)-on-failure
# behavior is already covered by require_existing_base_dir_or_die's own
# tests and every cli/*.pl script's own startup-refusal test - repeating
# it here would be exactly the kind of duplication this ticket exists to
# remove, not add back.

done_testing();
