use strict;
use warnings;

# TGT-310 (found via a scheduled JOB-004 improvement hunt): D2TG::RetryCli::run
# is exercised end to end by cli/retry-download.pl/cli/retry-transcription.pl's
# own existing tests, but only via real subprocesses - Devel::Cover has no
# visibility into a subprocess's own execution, so those tests alone leave
# this module showing 0% coverage against the project's mandatory 100%
# statement+subroutine gate on touched lib/ modules. This file calls
# D2TG::RetryCli::run directly, in-process, covering every branch - same
# CORE::GLOBAL::exit interception technique already established by
# t/186-open-store-or-die-coverage.t and its own precedents (a bare exit's
# CORE::GLOBAL::exit vs. CORE::exit binding is decided at compile time, so
# the override must be installed in a BEGIN block before D2TG::RetryCli is
# loaded).
our $captured_exit;

BEGIN {
    *CORE::GLOBAL::exit = sub {
        $captured_exit = $_[0] // 0;
        die "TGT310-TEST-EXIT\n";
    };
}

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

require D2TG::RetryCli;

# Helper: run D2TG::RetryCli::run(%args), capturing STDOUT/STDERR and the
# intercepted exit code, without ever letting a real exit() tear down the
# test process.
sub _run_capturing {
    my (%args) = @_;

    local $captured_exit;
    my ( $stdout, $stderr ) = ( '', '' );
    open my $out_fh, '>', \$stdout or die $!;
    open my $err_fh, '>', \$stderr or die $!;
    local *STDOUT = $out_fh;
    local *STDERR = $err_fh;

    my $survived = eval { D2TG::RetryCli::run(%args); 1 };
    my $catch_error = $@;
    close $out_fh;
    close $err_fh;

    ok( !$survived, 'D2TG::RetryCli::run never returns - it always exits' );
    is( $catch_error, "TGT310-TEST-EXIT\n", 'run() reached exit() - the interception sentinel fired' );

    return ( $stdout, $stderr, $captured_exit );
}

my @common_args = (
    label            => 'download',
    store            => bless( {}, 'Fake::Store' ),
    telegram_builder => sub { return bless {}, 'Fake::Telegram' },
    retry            => sub { die "retry should not be called in this case\n" },
    partial_note        => 'download succeeded but the history record could not be written yet',
    retry_command_name  => 'd2 tg.retry-download',
    format_success      => sub {
        my ($row) = @_;
        return " - GET ATTACHMENT WITH: d2 tg.attachment $row->{chat_id} $row->{message_id}";
    },
);

my $sample_row = {
    id => 1, chat_id => 42, message_id => 99, file_id => 'AB',
    error => 'boom', created_at => '2026-09-18 10:00:00',
};

# 1. List mode, empty queue.
{
    my ( $stdout, undef, $exit ) = _run_capturing(
        @common_args, argv => [], list => sub { return []; },
    );
    is( $exit, 0, 'empty list mode exits 0' );
    is( $stdout, "No failed downloads queued.\n", 'empty list mode prints the empty-queue message' );
}

# 2. List mode, non-empty queue.
{
    my ( $stdout, undef, $exit ) = _run_capturing(
        @common_args, argv => [], list => sub { return [$sample_row]; },
    );
    is( $exit, 0, 'non-empty list mode exits 0' );
    like( $stdout, qr/^\[1\] chat_id=42 message_id=99 file_id=AB error="boom" queued_at=2026-09-18 10:00:00\n/,
        'non-empty list mode prints each queued row' );
}

# 3. --all, empty queue.
{
    my ( $stdout, undef, $exit ) = _run_capturing(
        @common_args, argv => ['--all'], list => sub { return []; },
    );
    is( $exit, 0, '--all with an empty queue exits 0' );
    is( $stdout, "No failed downloads queued.\n", '--all with an empty queue prints the empty-queue message' );
}

# 4. Single id, not found.
{
    my ( undef, $stderr, $exit ) = _run_capturing(
        @common_args, argv => ['1'], list => sub { return []; },
    );
    is( $exit, 1, 'a single id not found in the queue exits 1' );
    is( $stderr, "No queued failed download with id 1.\n", 'a single id not found prints the not-found message' );
}

# 5. STORE ERROR: the list coderef itself dies.
{
    my ( undef, $stderr, $exit ) = _run_capturing(
        @common_args, argv => [], list => sub { die "database is locked\n"; },
    );
    is( $exit, 1, 'a failing list coderef exits 1' );
    like( $stderr, qr/^STORE ERROR: failed_downloads failed - /, 'a failing list coderef reports a classified STORE ERROR' );
}

# 6. --all, retry succeeds.
{
    my ( $stdout, undef, $exit ) = _run_capturing(
        @common_args,
        argv  => ['--all'],
        list  => sub { return [$sample_row]; },
        retry => sub { return ( 1, '/real/local/path', 0 ); },
    );
    is( $exit, 0, 'a fully successful retry exits 0' );
    is( $stdout, "RETRY OK [1] chat_id=42 message_id=99 - GET ATTACHMENT WITH: d2 tg.attachment 42 99\n",
        'a fully successful retry prints RETRY OK via format_success, never the raw path' );
}

# 7. Single id, retry fails (not expired).
{
    my ( undef, $stderr, $exit ) = _run_capturing(
        @common_args,
        argv  => ['1'],
        list  => sub { return [$sample_row]; },
        retry => sub { return ( 0, 'HTTP request failed (status 500)', undef ); },
    );
    is( $exit, 1, 'a non-expired retry failure exits 1' );
    like( $stderr, qr/^RETRY FAILED \[1\] chat_id=42 message_id=99: HTTP request failed \(status 500\)\n/,
        'a non-expired retry failure prints RETRY FAILED' );
}

# 8. Single id, retry fails (expired file_id).
{
    my ( undef, $stderr, $exit ) = _run_capturing(
        @common_args,
        argv  => ['1'],
        list  => sub { return [$sample_row]; },
        retry => sub { return ( 0, 'file is no longer available', undef ); },
    );
    is( $exit, 1, 'an expired-file retry failure exits 1' );
    like( $stderr, qr/^RETRY EXPIRED \[1\] chat_id=42 message_id=99: /,
        'an expired-file retry failure prints RETRY EXPIRED, not RETRY FAILED' );
}

# 9. Single id, retry succeeds but still queued (partial).
{
    my ( $stdout, undef, $exit ) = _run_capturing(
        @common_args,
        argv  => ['1'],
        list  => sub { return [$sample_row]; },
        retry => sub { return ( 1, '/real/local/path', 1 ); },
    );
    is( $exit, 1, 'a still-queued partial success exits 1, never 0' );
    like( $stdout, qr/^RETRY PARTIAL \[1\] chat_id=42 message_id=99 - download succeeded but the history record could not be written yet; the entry remains queued \(still queued\) and will be retried automatically, or retry again with d2 tg\.retry-download 1\n/,
        'a still-queued partial success prints RETRY PARTIAL, naming the retry command' );
}

done_testing();
