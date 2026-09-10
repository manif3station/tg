use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);

# TGT-164 (found via a scheduled bug hunt): D2TG_CHAT_ID's canonical-
# shape validation (TGT-155's require_chat_id_or_warn) is only ever
# called when the CLI does NOT declare its own --chat_id group
# ($has_cli_groups). When the CLI DOES declare its own group (TGT-049's
# multi-bot support), cli/poller.pl's second D2TG::Config::bot_groups
# call still silently folds the raw, unvalidated D2TG_CHAT_ID in as an
# ADDITIONAL implicit group - the malformed env value is never caught,
# it just becomes a broken third poll group.

my $poller_cli = File::Spec->catfile( $Bin, '..', 'cli', 'poller.pl' );

# A malformed env value must be caught and refused BEFORE any poll loop
# starts. Since a buggy pre-fix poller silently proceeds to poll
# instead of refusing (hanging forever rather than exiting), this reads
# with a bounded timeout instead of blocking indefinitely on either
# process exit or a line of stdout - a timeout here means "never
# refused", which is itself the failure this test exists to catch.
sub run_with_timeout {
    my ( $timeout, @cmd ) = @_;

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $pid = IPC::Open3::open3( my $in, $child_out, $child_err, @cmd );

    my ( $exited, $rc, $err_line );
    eval {
        local $SIG{ALRM} = sub { die "TIMEOUT\n" };
        alarm($timeout);
        waitpid( $pid, 0 );
        $rc = $? >> 8;
        $exited = 1;
        alarm(0);
    };
    my $timed_out = $@ && $@ eq "TIMEOUT\n";

    if ($timed_out) {
        kill 'KILL', $pid;
        waitpid( $pid, 0 );
    }

    local $/;
    $err_line = eof($child_err) ? '' : readline($child_err) // '';
    close $_ for grep { defined } ( $in, $child_out, $child_err );

    return ( $exited ? 1 : 0, $rc, $err_line, $timed_out ? 1 : 0 );
}

{
    # The failure scenario: CLI declares its own --chat_id/--bot group,
    # but D2TG_CHAT_ID is malformed (whitespace-padded around an
    # otherwise-valid id, exactly the shape TGT-155 already refuses in
    # the env-only path). This must still be refused, not silently
    # folded in as an extra broken group (which would otherwise proceed
    # straight into a real poll loop and never exit at all).
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_CHAT_ID} = ' 456 ';
    delete $ENV{D2TG_TOKEN};

    my ( $exited, $rc, $err, $timed_out ) =
      run_with_timeout( 5, $poller_cli, '--chat_id', '999', '--bot', 'sometoken' );

    ok( !$timed_out,
        'a malformed D2TG_CHAT_ID env value causes a prompt refusal, not a hang inside a real poll loop' );
    isnt( $rc, 0,
        'a malformed D2TG_CHAT_ID env value is refused (non-zero exit) even when the CLI also declares its own --chat_id group' )
      unless $timed_out;
    like( $err, qr/D2TG_CHAT_ID/,
        'the refusal names D2TG_CHAT_ID, not a generic/unrelated error' )
      unless $timed_out;
}

{
    # Regression: a well-formed D2TG_CHAT_ID env value alongside CLI
    # groups must keep working exactly as before - this fix must not
    # break TGT-049's own multi-bot/--chat_id parsing.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_CHAT_ID} = '12345';
    delete $ENV{D2TG_TOKEN};

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $pid = IPC::Open3::open3(
        my $in, $child_out, $child_err,
        $poller_cli, '--chat_id', '999', '--bot', 'sometoken'
    );

    my $first_line = <$child_out>;
    like( $first_line, qr/\S/,
        'a well-formed env D2TG_CHAT_ID alongside CLI --chat_id/--bot groups still starts up normally (no regression)' );

    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    close $_ for grep { defined } ( $in, $child_out, $child_err );
}

{
    # A Codex review during this ticket asked whether an empty-but-set
    # D2TG_CHAT_ID ('') should also be refused here. It deliberately is
    # NOT: D2TG::Config::bot_groups' own env-folding condition (defined
    # $env_chat_id && length $env_chat_id) never folds an empty string
    # in as a group either, so there is no broken extra group for this
    # guard to prevent - an empty env value behaves identically to an
    # unset one throughout this whole code path, by design. This locks
    # that decision down as a regression test, not just a comment.
    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_CHAT_ID} = '';
    delete $ENV{D2TG_TOKEN};

    require IPC::Open3;
    require Symbol;
    my ( $child_out, $child_err ) = ( Symbol::gensym(), Symbol::gensym() );
    my $pid = IPC::Open3::open3(
        my $in, $child_out, $child_err,
        $poller_cli, '--chat_id', '999', '--bot', 'sometoken'
    );

    my $first_line = <$child_out>;
    like( $first_line, qr/\S/,
        'an empty-but-set D2TG_CHAT_ID alongside CLI --chat_id/--bot groups still starts up normally, same as unset' );

    kill 'KILL', $pid;
    waitpid( $pid, 0 );
    close $_ for grep { defined } ( $in, $child_out, $child_err );
}

done_testing();
