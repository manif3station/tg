use strict;
use warnings;

# TGT-177: extract_db_flag_or_die wraps extract_db_flag's own
# eval/print-to-STDERR/exit(1) pattern, previously duplicated
# identically across 10 cli/*.pl scripts, matching the identical
# extraction TGT-172 already did for resolve_alias_dir_or_die. Same
# CORE::GLOBAL::exit interception technique for the same reason: a
# bare `exit` call's binding is decided at compile time, so the
# override must be installed before D2TG::Config is loaded.
our $captured_exit;
our $intercept_exit;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        if ($intercept_exit) {
            $captured_exit = $_[0] // 0;
            die "TGT177-TEST-EXIT\n";
        }
        return CORE::exit(@_);
    };
}

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::Config;

{
    my ( $alias, @rest ) = D2TG::Config::extract_db_flag_or_die( '--db', 'myalias', 'positional' );
    is( $alias, 'myalias', 'extract_db_flag_or_die returns the alias on success, same as extract_db_flag' );
    is_deeply( \@rest, ['positional'], '...and the remaining args, same as extract_db_flag' );
}

{
    local $captured_exit;
    local $intercept_exit = 1;

    my $stderr = '';
    open my $stderr_fh, '>', \$stderr or die $!;
    local *STDERR = $stderr_fh;

    my $direct_error;
    { eval { D2TG::Config::extract_db_flag('--db') }; $direct_error = $@; }

    my $survived = eval { D2TG::Config::extract_db_flag_or_die('--db'); 1 };
    my $catch_error = $@;
    close $stderr_fh;

    ok( !$survived, 'extract_db_flag_or_die does not return on failure - the sentinel exception propagated out of eval' );
    is( $catch_error, "TGT177-TEST-EXIT\n", 'the override intercepted the exit() call, confirming interception actually happened rather than silently passing' );
    is( $captured_exit, 1, 'extract_db_flag_or_die exits 1 on failure, same as every call site did before this refactor' );
    is( $stderr, $direct_error, 'extract_db_flag_or_die prints exactly the same error to STDERR that extract_db_flag itself dies with - byte-for-byte, not just a substring match' );
}

done_testing();
