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

for my $case ( [ 'status.pl', qr/^poller: not running$/m ], [ 'whoami.pl', qr/^d2tg version:/m ] ) {
    my ( $script, $success_pattern ) = @$case;
    my $cli         = File::Spec->catfile( $Bin, '..', 'cli', $script );
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';

    # These 2 accept no other flags, so --db is always both first and
    # only - this is a behavior-preserving refactor for them (confirmed
    # by every existing assertion for these scripts continuing to pass
    # unchanged), not a distinguishing regression test on its own.
    my $out = `$cli --db testalias`;
    is( $? >> 8, 0, "cli/$script still accepts --db in its only valid (leading) position after the refactor" );
    like( $out, $success_pattern, 'and still reports correctly' );

    # -d, not just --db.
    my $out2 = `$cli -d testalias`;
    is( $? >> 8, 0, "cli/$script accepts -d (short form) too" );
    like( $out2, $success_pattern, 'and still reports correctly with -d' );

    # Codex review finding: prove the alias VALUE actually flows through
    # to resolution (not just that its token pair is removed from argv)
    # by using a name that isn't a registered alias at all, and
    # confirming the resulting error names that exact bogus value.
    my $bad_out = `$cli --db this-alias-does-not-exist-tgt124 2>&1`;
    isnt( $? >> 8, 0, "cli/$script refuses an unregistered --db alias" );
    like( $bad_out, qr/this-alias-does-not-exist-tgt124/,
        'the error names the exact bogus alias - proving the value was genuinely resolved, not just consumed from argv' );

    # A bare trailing --db (no value at all) must still refuse clearly,
    # matching D2TG::Config::shift_flag_value's own existing contract.
    my $bare_out = `$cli --db 2>&1`;
    isnt( $? >> 8, 0, "cli/$script refuses a bare trailing --db with no value" );
    like( $bare_out, qr/--db\/-d requires a value/, 'the message names the actual problem' );
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

    # -d, not just --db, in the same trailing position.
    my $out_short = `$send_cli 999 $missing_path -d testalias 2>&1`;
    like( $out_short, qr/file not found/i, '-d (short form) works the same way in trailing position' );

    # Codex review finding: prove the alias VALUE genuinely flows
    # through to resolution (not just that its token pair vanishes from
    # argv) - resolve_alias_dir runs BEFORE the file-existence check, so
    # a bogus alias must produce ITS OWN distinct error, naming the
    # bogus value, rather than falling through to "file not found".
    my $bad_out = `$send_cli 999 $missing_path --db this-alias-does-not-exist-tgt124 2>&1`;
    isnt( $? >> 8, 0, 'cli/send.pl refuses an unregistered --db alias given in trailing position' );
    like( $bad_out, qr/this-alias-does-not-exist-tgt124/,
        'the error names the exact bogus alias, proving it was genuinely resolved from its trailing position, not just discarded' );
    unlike( $bad_out, qr/file not found/i, 'the alias-resolution failure is reported, not masked by the later file-existence check' );
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
