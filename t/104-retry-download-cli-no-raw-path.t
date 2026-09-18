use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-146 (scheduled hourly bug hunt, JOB-003): cli/retry-download.pl's
# own success-path print interpolated $result_or_error - the raw local
# filesystem path D2TG::Download::retry_failed_download returns on
# success - directly into its "RETRY OK" stdout line, leaking a real
# path onto the target project's tira.policy.bridge (monitor-output,
# visible to anyone who can read that board). This is the exact class
# of leak TGT-133 closed everywhere else (D2TG::Poller's own
# _print_attachment_template, cli/attachment.pl); this one entrypoint
# was missed because it prints retry_failed_download's raw return value
# directly instead of going through the same never-expose-the-real-path
# indirection.
#
# TGT-310 (found via a scheduled JOB-004 improvement hunt): the actual
# "RETRY OK ..." print statement moved into the new shared
# lib/D2TG/RetryCli.pm as part of extracting cli/retry-download.pl and
# cli/retry-transcription.pl's own duplicated skeleton. D2TG::RetryCli::
# run legitimately passes $result_or_error through to whichever
# format_success closure the caller supplied (cli/retry-transcription.pl's
# own closure genuinely needs it, to print the recovered transcript
# text) - the real safety property this test protects is narrower and
# still checked at its true source: cli/retry-download.pl's own
# format_success closure specifically must never use $result_or_error
# to build its output, since for THIS script it would be the raw local
# filesystem path.
#
# A full functional test would need to mock both D2TG::Telegram's
# get_file HTTP call and the subsequent raw byte-fetch, for which this
# script has no injectable seam (unlike D2TG::Download::retry_failed_
# download itself, which t/83-failed-download-queue.t already covers
# via an injected `ua`) - so this is a structural/source-inspection
# regression test instead, matching this project's own precedent
# (t/88-poller-help-pod-parity.t) for exactly this situation.

{
    my $module_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'RetryCli.pm' );
    open my $fh, '<', $module_path or die "can't read $module_path: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    my ($success_line) = $source =~ /^\s*(print "RETRY OK.*?;\n)/ms;
    ok( defined $success_line, 'found the RETRY OK success print statement in lib/D2TG/RetryCli.pm' );

    like( $success_line, qr/\$format_success->\(/,
        'D2TG::RetryCli::run\'s RETRY OK line composes its trailing text only via the caller-supplied format_success coderef' );
}

{
    my $script_path = File::Spec->catfile( $Bin, '..', 'cli', 'retry-download.pl' );
    open my $fh, '<', $script_path or die "can't read $script_path: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    my ($closure) = $source =~ /(format_success\s*=>\s*sub\s*\{.*?\n\s*\},\n\);)/s;
    ok( defined $closure, 'found the format_success closure in cli/retry-download.pl' );

    unlike( $closure, qr/\$result_or_error/,
        'the format_success closure never interpolates the raw local path ($result_or_error) - TGT-146' );

    like( $closure, qr/GET ATTACHMENT WITH/,
        'the format_success closure instead names the d2 tg.attachment fetch command' );
}

done_testing();
