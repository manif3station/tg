use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";
use File::Temp qw(tempdir tempfile);
use File::Spec;
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-124 (found via a scheduled improvement-hunt): cli/status.pl,
# cli/whoami.pl, and cli/send.pl each hand-rolled their own --db/-d
# parsing loop instead of using the shared D2TG::Config::extract_db_flag
# helper every other cli/*.pl script already uses. extract_db_flag scans
# the ENTIRE argument list, so --db can appear anywhere; the hand-rolled
# loops stopped at the first non---db/-d token, so --db was only
# recognized when it came before everything else. This is a real,
# user-facing behavioral divergence for cli/send.pl specifically, since
# it's the only one of the three that also accepts other flags/
# positional arguments --db could legitimately follow.

{
    my $status_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'status.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    # status.pl accepts no other flags, so --db is always both first and
    # only - this is a behavior-preserving refactor for it (confirmed by
    # every existing t/80-poller-status.t assertion continuing to pass
    # unchanged), not a distinguishing regression test on its own.
    my $out = `$status_cli --db testalias`;
    is( $? >> 8, 0, 'cli/status.pl still accepts --db in its only valid (leading) position after the refactor' );
    like( $out, qr/^poller: not running$/m, 'and still reports correctly' );
}

{
    my $whoami_cli  = File::Spec->catfile( $Bin, '..', 'cli', 'whoami.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    # Same as status.pl - whoami.pl accepts no other flags either.
    my $out = `$whoami_cli --db testalias`;
    is( $? >> 8, 0, 'cli/whoami.pl still accepts --db in its only valid (leading) position after the refactor' );
    like( $out, qr/^d2tg version:/m, 'and still reports correctly' );
}

# The real, distinguishing regression: cli/send.pl accepts other flags
# and positional arguments --db can legitimately follow.
{
    my $send_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( undef, $missing_path ) = tempfile( SUFFIX => '.jpg', UNLINK => 1 );
    unlink $missing_path;    # deliberately nonexistent - proves the file-path validation still ran using the resolved --db alias

    # --db AFTER the chat_id and file_path positionals - the exact shape
    # the improvement-hunt found broken (previously fell into "Unrecognized
    # argument" / leftover-argv territory instead of resolving --db at all).
    my $out = `$send_cli 999 $missing_path --db testalias 2>&1`;
    my $rc  = $? >> 8;

    isnt( $rc, 0, 'cli/send.pl with --db trailing after the positionals still refuses (the file genuinely does not exist)' );
    like( $out, qr/file not found/i,
        'the refusal is the file-existence check, not a bogus "unrecognized argument" - proving --db WAS actually resolved from its trailing position' );
    unlike( $out, qr/Unrecognized argument/i,
        'crucially, --db is no longer misparsed as an unrecognized positional argument just because it came after chat_id/file_path' );
}

{
    # Regression: the existing leading---db case (and env-var fallback)
    # must be completely unaffected by the refactor.
    my $send_cli    = File::Spec->catfile( $Bin, '..', 'cli', 'send.pl' );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    my ( undef, $missing_path ) = tempfile( SUFFIX => '.jpg', UNLINK => 1 );
    unlink $missing_path;

    my $out = `$send_cli --db testalias 999 $missing_path 2>&1`;
    like( $out, qr/file not found/i, '--db in its original leading position still works exactly as before' );
}

done_testing();
