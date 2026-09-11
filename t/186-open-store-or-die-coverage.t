use strict;
use warnings;

# TGT-186: open_store_or_die is exercised end to end by
# t/186-cli-store-startup-crash.t, but only via real subprocesses (each
# cli/*.pl script run as its own perl process) - Devel::Cover has no
# visibility into a subprocess's own execution, so that test alone
# leaves this sub showing 0% coverage against the project's mandatory
# 100% statement+subroutine gate on touched lib/ modules. This file
# calls it directly, in-process, covering both the success and failure
# branches - same CORE::GLOBAL::exit interception technique already
# established by t/172-resolve-alias-dir-or-die.t and
# t/177-extract-db-flag-or-die.t (a bare exit's CORE::GLOBAL::exit vs.
# CORE::exit binding is decided at compile time, so the override must be
# installed in a BEGIN block before D2TG::Poller/D2TG::Store are loaded).
our $captured_exit;
our $intercept_exit;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        if ($intercept_exit) {
            $captured_exit = $_[0] // 0;
            die "TGT186-TEST-EXIT\n";
        }
        return CORE::exit(@_);
    };
}

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);

require D2TG::Poller;
require D2TG::Store;

{
    # Success path: D2TG::Store->new returns normally - open_store_or_die
    # must return that same object, unmodified.
    my $fake_store = bless {}, 'D2TG::Store';
    local *D2TG::Store::new = sub { return $fake_store; };

    my $base_dir = tempdir( CLEANUP => 1 );
    my $result = D2TG::Poller::open_store_or_die(
        skill_root    => $base_dir,
        base_dir      => $base_dir,
        admin_chat_id => '12345',
    );

    is( $result, $fake_store, 'open_store_or_die returns the D2TG::Store object on success, unmodified' );
}

{
    # Failure path: D2TG::Store->new dies - open_store_or_die must print
    # the exact scrubbed refusal (never the raw exception) and exit 1,
    # matching TGT-183's own established refusal text verbatim.
    local *D2TG::Store::new = sub { die "DBI connect(...) failed: unable to open database file at .../D2TG/Store.pm line 18.\n"; };

    my $base_dir = tempdir( CLEANUP => 1 );

    local $captured_exit;
    local $intercept_exit = 1;

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    local *STDERR = $stderr_fh;

    my $survived = eval {
        D2TG::Poller::open_store_or_die(
            skill_root    => $base_dir,
            base_dir      => $base_dir,
            admin_chat_id => '12345',
        );
        1;
    };
    my $catch_error = $@;
    close $stderr_fh;

    ok( !$survived, 'open_store_or_die does not return on failure - the sentinel exception propagated out of eval' );
    is( $catch_error, "TGT186-TEST-EXIT\n", 'the override intercepted the exit() call, confirming interception actually happened' );
    is( $captured_exit, 1, 'open_store_or_die exits 1 on failure' );
    is( $stderr, "Failed to open local storage (an unexpected error) - refusing to start.\n",
        'open_store_or_die prints the exact scrubbed refusal, byte-for-byte - never the raw exception' );
}

done_testing();
