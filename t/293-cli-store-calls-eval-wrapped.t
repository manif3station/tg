use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-293 (found via a user-requested comprehensive bug/improvement
# sweep): D2TG::Store->new sets RaiseError => 1 on its DBI handle, and
# D2TG::Poller::Safe::open_store_or_die only wraps the constructor call
# itself, not any later method call on the returned $store object. ~13
# call sites across 7 cli scripts invoked $store->method(...) completely
# unwrapped by eval - a locked/busy SQLite database at the exact moment
# any of these calls runs raw-crashes with an uncaught DBI exception
# (which can embed the real db path) instead of this project's own
# established clean-refusal convention (STORE ERROR: ... failed -
# REASON, exit 1). Only cli/approve.pl's own $store-> calls were
# correctly eval-wrapped/classified in this whole file family - this is
# the exact bug class TGT-183/186/195 already fixed for other call
# sites, just never swept this widely.
#
# Source-inspection regression test, matching this project's own
# established precedent for this exact situation
# (t/195-approve-store-calls-classified-not-raw.t) - a real
# locked-database failure occurring strictly AFTER D2TG::Store->new
# already succeeded is not reliably reproducible black-box via a CLI
# subprocess without fragile timing/concurrency tricks. Each named call
# site is checked individually (an eval-wrapped pattern that must be
# present) rather than by a generic strip-all-eval-blocks-then-grep
# approach, since several call sites dereference with C<@{ ... }>,
# whose own inner C<{ }> defeats a naive non-nested brace strip.
#
# TGT-310 (found via a scheduled JOB-004 improvement hunt): retry-
# download.pl/retry-transcription.pl's own $store->failed_downloads/
# failed_transcriptions calls, and the eval-wrap+classify+STORE ERROR
# handling around them, moved into the new shared
# lib/D2TG/RetryCli.pm (D2TG::RetryCli::_list_or_die) - a pure
# extraction, the safety property still holds, just relocated. Removed
# from this script-level %expect (the pattern would no longer match -
# these 2 scripts now only pass a list coderef to D2TG::RetryCli::run,
# they don't eval-wrap the call themselves) and covered instead by
# t/310-retrycli-store-call-eval-wrapped.t, which checks the new home
# directly.
#
# TGT-314 (found via a scheduled JOB-004 improvement hunt): the
# classify+print+exit shape itself moved out of every script in this
# list, into a new shared D2TG::Poller::Safe::die_store_error helper -
# each script's own classify_store_error/"STORE ERROR: ... failed"
# lines were replaced by a single die_store_error(...) if $@; call per
# site. The per-script classify/STORE-ERROR checks below were adapted
# to assert on die_store_error instead; die_store_error's own internal
# shape is covered by t/314-die-store-error-helper.t and Safe.pm's own
# source directly, not re-asserted per-script here.

my %expect = (
    'history.pl' => [
        qr/eval \{\s*\n\s*\(\s*defined \$since \|\| defined \$until\s*\)\s*\n\s*\?\s*\$store->messages_in_range\(/s,
        qr/reverse \$store->recent_messages\(/,
    ],
    'attachment.pl' => [
        qr/my \$local_path = eval \{ \$store->get_attachment_path\(/,
        # TGT-311 (explicit user-requested architecture change):
        # attachment.pl now also marks the message read on a
        # successful fetch, the same eval-wrapped pattern.
        qr/eval \{ \$store->mark_read\(/,
    ],
    'unread.pl' => [
        qr/my \@unread = eval \{ \$store->unread_messages\(/,
        qr/my \@queued_failures = eval \{ \@\{ \$store->failed_downloads \} \}/,
        qr/my \@queued_transcriptions = eval \{ \@\{ \$store->failed_transcriptions \} \}/,
    ],
    'reply.pl' => [
        qr/my \$text_only_replies = eval \{ \$store->text_only_replies\(/,
    ],
    'text-only-replies.pl' => [
        qr/my \$flagged = eval \{ \$store->text_only_replies \}/,
    ],
    # TGT-311 (explicit user-requested architecture change): the new
    # cli/fetch.pl has the exact same eval-wrap-classify-STORE ERROR
    # obligation as every other script in this list.
    'fetch.pl' => [
        qr/my \$message = eval \{ \$store->get_message\(/,
        qr/eval \{ \$store->mark_read\(/,
    ],
);

for my $script ( sort keys %expect ) {
    my $script_path = File::Spec->catfile( $Bin, '..', 'cli', $script );
    open my $fh, '<', $script_path or die "can't read $script_path: $!";
    local $/;
    my $source = <$fh>;
    close $fh;

    for my $pattern ( @{ $expect{$script} } ) {
        like( $source, $pattern, "cli/$script: a \$store-> call is wrapped in eval, not called raw" );
    }

    # Count every $store-> occurrence in the file (excluding POD/comment
    # mentions) and confirm it matches exactly the number this ticket
    # accounts for via the explicit per-call patterns above - a plain
    # occurrence count alone can't tell wrapped from raw, but combined
    # with the explicit "eval { $store->method(" patterns already
    # required to match above, an equal total count means no additional,
    # still-unwrapped $store-> call site was left behind in the file.
    my @all_calls        = ( $source =~ /\$store->/g );
    my @commented_calls  = map { /\$store->/g } grep { /^\s*#/ } split /\n/, $source;
    my $real_call_count  = scalar(@all_calls) - scalar(@commented_calls);
    is( $real_call_count, scalar( @{ $expect{$script} } ),
        "cli/$script: every real \$store-> call site is accounted for by an eval-wrapped pattern above" );

    like( $source, qr/D2TG::Poller::Safe::die_store_error\( \$@, /,
        "cli/$script: hands a store-call failure to the shared die_store_error helper" );
}

done_testing();
