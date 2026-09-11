use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-198 (found via a scheduled JOB-004 improvement hunt): the
# eval + D2TG::Poller::_classify_store_error + print STDERR "STORE
# ERROR [chat_id]: DESC failed - REASON" pattern is hand-duplicated
# across D2TG::Poller.pm (is_allowed x3, add_pending) and
# D2TG::Download.pm (record_message, remove_failed_download,
# mark_failed_download_downloaded) - 7 identically-shaped inline
# blocks, while D2TG::Reply.pm already has an equivalent private
# helper (_store_write_safe, TGT-192) doing exactly this. This test
# is a structural (source-inspection) regression test, not a
# functional one - there is no injectable seam distinguishing
# "duplicated inline" from "routed through a shared helper" other
# than the source text itself, matching this project's own
# established precedent (t/104, t/88, t/195).

my $poller_path   = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Poller.pm' );
my $download_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Download.pm' );

my $poller_src   = _slurp($poller_path);
my $download_src = _slurp($download_path);

# The shared, PUBLIC helper must exist in D2TG::Poller.pm (the module
# every other caller already imports _classify_store_error from).
like(
    $poller_src,
    qr/^sub store_write_safe \{/m,
    'D2TG::Poller defines a public store_write_safe helper'
);

# Every inline "eval { ... }; if ($@) { ... _classify_store_error($@) ...
# print STDERR "STORE ERROR [...]: ... failed - $reason\n"; ... }"
# block outside of store_write_safe's own definition must be gone -
# each of the 7 identified call sites must instead call the shared
# helper.
my $inline_block_re = qr/
    eval \s* \{
    (?: (?! ^sub \s ) . ){0,400}?
    if \s* \( \s* \$\@ \s* \) \s* \{
    (?: (?! ^sub \s ) . ){0,400}?
    _classify_store_error \( \$\@ \)
    (?: (?! ^sub \s ) . ){0,400}?
    print \s+ STDERR \s+ "STORE \s+ ERROR
/msx;

unlike(
    $poller_src,
    $inline_block_re,
    'D2TG::Poller.pm has zero remaining inline eval/classify/"STORE ERROR" blocks'
);

unlike(
    $download_src,
    $inline_block_re,
    'D2TG::Download.pm has zero remaining inline eval/classify/"STORE ERROR" blocks'
);

# Both modules must actually call the shared helper for their own
# store writes - a green result on the two checks above for the wrong
# reason (e.g. the whole pattern deleted instead of migrated) is
# caught here.
my $poller_calls = () = $poller_src =~ /\bstore_write_safe\(/g;
ok( $poller_calls >= 4,
    "D2TG::Poller.pm calls store_write_safe at least 4 times (is_allowed x3, add_pending) - found $poller_calls"
);

my $download_calls = () = $download_src =~ /\bD2TG::Poller::store_write_safe\(/g;
ok( $download_calls >= 3,
    "D2TG::Download.pm calls D2TG::Poller::store_write_safe at least 3 times (record_message, remove_failed_download, mark_failed_download_downloaded) - found $download_calls"
);

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "can't open $path: $!";
    local $/;
    return <$fh>;
}
