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
my $safe_path     = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Poller', 'Safe.pm' );
my $download_path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Download.pm' );

my $poller_src   = _code_only( _slurp($poller_path) );
my $safe_src     = _code_only( _slurp($safe_path) );
my $download_src = _code_only( _slurp($download_path) );

# TGT-275: store_write_safe (and its own _classify_store_error/
# classify_store_error dependency) relocated out of D2TG::Poller into
# D2TG::Poller::Safe, along with the other 7 non-run_once helpers, to
# bring D2TG::Poller.pm under the board's 500-line-per-module cap. The
# scan for remaining inline duplicates below must not flag
# store_write_safe's own canonical definition (which legitimately
# contains exactly this eval/classify/print shape) as itself a
# leftover duplicate - excise it before scanning, matching from its
# own "sub store_write_safe {" line up to the next top-level "sub ".
( my $safe_src_excluding_helper = $safe_src ) =~
  s/^sub store_write_safe \{.*?(?=^sub )//ms;

# The shared, PUBLIC helper must exist in D2TG::Poller::Safe (the
# module every other caller now calls classify_store_error from).
like(
    $safe_src,
    qr/^sub store_write_safe \{/m,
    'D2TG::Poller::Safe defines a public store_write_safe helper'
);

# Every inline "eval { ... }; if ($@) { ... classify_store_error($@) ...
# print STDERR "STORE ERROR [...]: ... failed - $reason\n"; ... }"
# block outside of store_write_safe's own definition must be gone -
# each of the 7 identified call sites must instead call the shared
# helper.
my $inline_block_re = qr/
    eval \s* \{
    (?: (?! ^sub \s ) . ){0,400}?
    if \s* \( \s* \$\@ \s* \) \s* \{
    (?: (?! ^sub \s ) . ){0,400}?
    classify_store_error \( \$\@ \)
    (?: (?! ^sub \s ) . ){0,400}?
    print \s+ STDERR \s+ "STORE \s+ ERROR
/msx;

unlike(
    $poller_src,
    $inline_block_re,
    'D2TG::Poller.pm has zero remaining inline eval/classify/"STORE ERROR" blocks'
);

unlike(
    $safe_src_excluding_helper,
    $inline_block_re,
    'D2TG::Poller::Safe.pm has zero remaining inline eval/classify/"STORE ERROR" blocks (outside store_write_safe itself)'
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
my $poller_calls = () = $poller_src =~ /\bD2TG::Poller::Safe::store_write_safe\(/g;
ok( $poller_calls >= 4,
    "D2TG::Poller.pm calls D2TG::Poller::Safe::store_write_safe at least 4 times (is_allowed x3, add_pending) - found $poller_calls"
);

my $download_calls = () = $download_src =~ /\bD2TG::Poller::Safe::store_write_safe\(/g;
ok( $download_calls >= 3,
    "D2TG::Download.pm calls D2TG::Poller::Safe::store_write_safe at least 3 times (record_message, remove_failed_download, mark_failed_download_downloaded) - found $download_calls"
);

done_testing();

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "can't open $path: $!";
    local $/;
    return <$fh>;
}

# Strips POD blocks and whole-line comments so the structural regex
# below only ever sees real code - without this, prose in a comment or
# POD block mentioning "eval", "_classify_store_error($@)" and
# "print STDERR ... STORE ERROR" close together (exactly the kind of
# prose this ticket's own commit messages/POD legitimately contain)
# would false-positive as a still-duplicated inline block.
sub _code_only {
    my ($src) = @_;
    $src =~ s/^=\w+.*?^=cut\s*$//msg;
    my @lines = grep { !/^\s*#/ } split /\n/, $src;
    return join( "\n", @lines );
}
