use strict;
use warnings;

# TGT-172: resolve_alias_dir_or_die wraps resolve_alias_dir's own
# eval/print-to-STDERR/exit(1) pattern, previously duplicated
# identically across 11 cli/*.pl scripts. Because a bare `exit` call's
# binding (CORE::exit vs. CORE::GLOBAL::exit) is decided at compile
# time, a plain `local *CORE::GLOBAL::exit` installed after
# D2TG::Config is loaded would NOT intercept its exit(1) call. The
# override below is installed in a BEGIN block, before D2TG::Config is
# loaded, so the helper's `exit 1` compiles against it - and gated
# behind a flag so it only actually intercepts during this file's own
# failure-path test below; Test::Builder's own real exit() at
# end-of-run is completely unaffected.
our $captured_exit;
our $intercept_exit;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        if ($intercept_exit) {
            $captured_exit = $_[0] // 0;
            die "TGT172-TEST-EXIT\n";
        }
        return CORE::exit(@_);
    };
}

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

{
    local $ENV{D2TG_DB};
    local $ENV{TIRA_HOME};
    my $dir = D2TG::Config::resolve_alias_dir_or_die( tira_home => '/tmp/or-die-success', paths => {} );
    is( $dir, '/tmp/or-die-success', 'resolve_alias_dir_or_die returns the resolved base_dir on success, same as resolve_alias_dir' );
}

{
    local $ENV{D2TG_DB};
    local $ENV{TIRA_HOME};
    local $captured_exit;
    local $intercept_exit = 1;

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    local *STDERR = $stderr_fh;

    my $direct_error;
    { local $ENV{D2TG_DB}; local $ENV{TIRA_HOME}; eval { D2TG::Config::resolve_alias_dir() }; $direct_error = $@; }

    my $survived = eval { D2TG::Config::resolve_alias_dir_or_die(); 1 };
    my $catch_error = $@;
    close $stderr_fh;

    ok( !$survived, 'resolve_alias_dir_or_die does not return on failure - the sentinel exception propagated out of eval' );
    is( $catch_error, "TGT172-TEST-EXIT\n", 'the override intercepted the exit() call, confirming interception actually happened rather than silently passing' );
    is( $captured_exit, 1, 'resolve_alias_dir_or_die exits 1 on failure, same as every call site did before this refactor' );
    is( $stderr, $direct_error, 'resolve_alias_dir_or_die prints exactly the same error to STDERR that resolve_alias_dir itself dies with - byte-for-byte, not just a substring match' );
}

done_testing();
