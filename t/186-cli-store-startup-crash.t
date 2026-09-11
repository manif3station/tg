use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use lib "$Bin/lib";
use Test::MandatoryDb qw(setup_mandatory_db_env);
use Test::CaptureStdio qw(run_capturing_stderr);

# TGT-186 (found via a scheduled JOB-003 hourly bug hunt, reproduced live
# against cli/history.pl): 7 cli/*.pl scripts (attachment, text-only-
# replies, approve, retry-download, history, reply, unread) shared the
# identical unwrapped D2TG::Store->new call TGT-183 already fixed only
# in cli/poller.pl - a storage-open failure crashed each one with a raw,
# uncaught Perl/DBI exception embedding the real db_path, instead of a
# clean scrubbed refusal. Now all 7 go through the shared
# D2TG::Poller::open_store_or_die helper. One test block per script,
# each using the same root-proof directory-collision technique as
# t/183's own test (pre-create the target db-file path as a directory -
# SQLite cannot open a directory as a database file, regardless of
# permissions or root), with each script's own minimal required
# positional args so every one reaches the D2TG::Store->new call.

sub assert_clean_refusal {
    my (%args) = @_;
    my ( $label, $cli, $extra_args, $extra_env ) = @args{qw(label cli extra_args extra_env)};

    my $fake_db_dir = tempdir( CLEANUP => 1 );
    setup_mandatory_db_env( $Bin, $fake_db_dir );
    local %ENV = %ENV;
    $ENV{D2TG_TOKEN}   = 'test-token';
    $ENV{D2TG_CHAT_ID} = '12345';
    $ENV{$_} = $extra_env->{$_} for keys %{ $extra_env || {} };

    my $blocking_path = File::Spec->catdir( $fake_db_dir, '.tira', 'telegram.messages.db' );
    make_path($blocking_path);

    my $script = File::Spec->catfile( $Bin, '..', 'cli', $cli );
    my ( $out, $rc, $err ) = run_capturing_stderr( $script, @{ $extra_args || [] } );

    isnt( $rc, 0, "$label: a startup-time storage failure exits non-zero" );
    unlike( $err, qr/\Q$fake_db_dir\E/, "$label: the STDERR message never contains the raw db_path" );
    unlike( $err, qr/at \S+\.pm line \d+/, "$label: the STDERR message is a clean refusal, not a raw uncaught Perl trace" );

    my @lines = split /\n/, $err;
    is( $lines[-1], 'Failed to open local storage (an unexpected error) - refusing to start.',
        "$label: the LAST STDERR line is the exact fixed, scrubbed refusal text" );
}

assert_clean_refusal( label => 'approve.pl',            cli => 'approve.pl',            extra_args => ['12345'] );
assert_clean_refusal( label => 'attachment.pl',         cli => 'attachment.pl',         extra_args => [ '12345', '1' ] );
assert_clean_refusal( label => 'history.pl',            cli => 'history.pl' );
assert_clean_refusal( label => 'reply.pl',               cli => 'reply.pl',               extra_args => [ '12345', 'hello' ] );
assert_clean_refusal( label => 'unread.pl',              cli => 'unread.pl' );
assert_clean_refusal( label => 'retry-download.pl',      cli => 'retry-download.pl' );
assert_clean_refusal( label => 'text-only-replies.pl',   cli => 'text-only-replies.pl' );

done_testing();
