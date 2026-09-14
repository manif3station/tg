use strict;
use warnings;

# TGT-230 (found via a scheduled JOB-004 improvement hunt):
# require_existing_base_dir_or_die wraps require_existing_base_dir's
# own eval/print-to-STDERR/exit(1) pattern, previously duplicated
# identically across 11 cli/*.pl scripts - the one remaining
# startup-guard call that never got its own _or_die sibling, unlike
# resolve_alias_dir_or_die (TGT-172) and open_store_or_die. Same
# CORE::GLOBAL::exit interception pattern as t/172, for the same
# compile-time-binding reason documented there.
our $captured_exit;
our $intercept_exit;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        if ($intercept_exit) {
            $captured_exit = $_[0] // 0;
            die "TGT230-TEST-EXIT\n";
        }
        return CORE::exit(@_);
    };
}

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use File::Temp qw(tempdir);

require D2TG::Config;

{
    my $dir = tempdir( CLEANUP => 1 );
    my $result = D2TG::Config::require_existing_base_dir_or_die($dir);
    is( $result, $dir, 'require_existing_base_dir_or_die returns the base_dir on success, same as require_existing_base_dir' );
}

{
    local $captured_exit;
    local $intercept_exit = 1;

    my $missing_dir = '/tmp/tgt230-does-not-exist-' . $$;

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    local *STDERR = $stderr_fh;

    my $direct_error;
    { eval { D2TG::Config::require_existing_base_dir($missing_dir) }; $direct_error = $@; }

    my $survived = eval { D2TG::Config::require_existing_base_dir_or_die($missing_dir); 1 };
    my $catch_error = $@;
    close $stderr_fh;

    ok( !$survived, 'require_existing_base_dir_or_die does not return on failure - the sentinel exception propagated out of eval' );
    is( $catch_error, "TGT230-TEST-EXIT\n", 'the override intercepted the exit() call, confirming interception actually happened' );
    is( $captured_exit, 1, 'require_existing_base_dir_or_die exits 1 on failure, same as every call site did before this refactor' );
    is( $stderr, $direct_error, 'require_existing_base_dir_or_die prints exactly the same error to STDERR that require_existing_base_dir itself dies with' );
}

done_testing();
