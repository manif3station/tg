use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use File::Spec;

# TGT-272 (found via a scheduled JOB-005 doc-accuracy hunt): TGT-269
# converted extract_bot_flag_or_die, extract_db_flag_or_die,
# resolve_alias_dir_or_die, and require_existing_base_dir_or_die into
# one-line forwarders onto the new shared D2TG::OrDie::or_die helper -
# but their own POD (3 .pod/.pm files + a docs/commands.md row) still
# described each one's OWN direct eval/print-STDERR/exit(1)
# implementation, as if each still hand-rolled the idiom itself.
# Accurate before TGT-269, stale now that the actual implementation
# delegates. This is a structural regression test guarding the whole
# drift class, not just this one instance - it fails if any of these 5
# locations ever stops mentioning D2TG::OrDie again.

my @files = (
    [ 'lib/D2TG/Reply/Args.pod',   qr/=head2 extract_bot_flag_or_die/ ],
    [ 'lib/D2TG/Config/Flags.pod', qr/=head2 extract_db_flag_or_die/ ],
    [ 'lib/D2TG/Config/Paths.pod', qr/=head2 resolve_alias_dir_or_die/ ],
    [ 'lib/D2TG/Config/Paths.pod', qr/=head2 require_existing_base_dir_or_die/ ],
    [ 'docs/commands.md',          qr/`extract_db_flag_or_die` \(TGT-177\)/ ],
);

for my $entry (@files) {
    my ( $rel, $anchor ) = @$entry;
    my $path = File::Spec->catfile( $Bin, '..', $rel );
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;

    # Find the section around the anchor function name and confirm it
    # mentions D2TG::OrDie somewhere nearby (within 700 chars after the
    # anchor) - not just anywhere in the whole file.
    my ($section) = $content =~ /($anchor.{0,700})/s;
    ok( defined $section, "$rel: found a section describing $anchor" );
    like( $section, qr/D2TG::OrDie/, "$rel: the $anchor section mentions the D2TG::OrDie delegation, not a stale hand-rolled description" )
      if defined $section;
}

# TGT-268 removed cli/reply.pl's and cli/send.pl's own "@ARGV >= 2"
# special-case around --bot handling - Reply/Args.pod's own
# extract_bot_flag_or_die section still claimed it existed.
{
    my $path = File::Spec->catfile( $Bin, '..', 'lib', 'D2TG', 'Reply', 'Args.pod' );
    open my $fh, '<', $path or die "$path: $!";
    local $/;
    my $content = <$fh>;
    close $fh;

    unlike( $content, qr/pre-check.{0,40}\@ARGV.{0,10}>=\s*2/s, "Reply/Args.pod no longer claims cli/send.pl/reply.pl pre-check \@ARGV >= 2 (removed by TGT-268)" );
}

done_testing();
