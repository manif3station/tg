use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);

# TGT-182 (found via a scheduled improvement hunt): the 5-line
# multipart reply_to_message_id field construction ("validate, then
# if defined append a form-data fragment to $body") appeared
# identically in both send_voice and _send_file (backing
# send_photo/send_document) - extracted into a single helper, matching
# this project's own established "found it twice, extract it"
# convention (TGT-167/170/171/172/177/181). The real behavioral
# guarantee (correct multipart bytes, correct per-method error
# message) is t/32-message-id-and-reply-threading.t's and
# t/79-outbound-media-send.t's job, already passing unchanged - this
# file only guards the structural refactor itself, the same narrow
# scope t/181's own dedup test settled on.

my $source_path = "$Bin/../lib/D2TG/Telegram.pm";
open my $fh, '<', $source_path or die $!;
local $/;
my $source = <$fh>;
close $fh;

my $duplicate_pattern_count = () = $source =~ /
    if\ \(\ defined\ \$opts\{reply_to_message_id\}\ \)\ \{\n
    \s*\$body\ \.=\ "--\$boundary\\r\\n"\n
/gx;

is( $duplicate_pattern_count, 0,
    'the duplicated multipart reply_to_message_id field-construction block appears 0 times outside the new helper (TGT-182 AC)' );

my $helper_call_count = () = $source =~ /_append_reply_to_message_id_field\(/g;

is( $helper_call_count, 2,
    'the new helper is called from exactly 2 places - send_voice and _send_file' );

# Codex QA-stage review finding (same class TGT-181's own dedup test
# was caught on): a bare global count proves only that 2 syntactic
# call-like occurrences exist SOMEWHERE in the file, not that they sit
# in send_voice and _send_file specifically - it's a source-text
# regex, not a parser, and cannot prove AST-level branch/subroutine
# membership. Anchor each call to a nearby, distinguishing string
# literal unique to its own subroutine, so a call missing from its
# real caller (or duplicated in the wrong one) is caught - still not a
# full parser-based proof, an accepted, documented limitation.
my %expected_near = (
    'send_voice' => qr/_append_reply_to_message_id_field\(\s*\\\$body,\s*\$boundary,\s*'sendVoice',\s*\$opts\{reply_to_message_id\}\s*\).*?name="voice";\s*filename="\$filename"/s,
    '_send_file'  => qr/my \$escaped_filename = \$safe_filename.*?_append_reply_to_message_id_field\(\s*\\\$body,\s*\$boundary,\s*\$method,\s*\$opts\{reply_to_message_id\}\s*\)/s,
);

for my $label ( sort keys %expected_near ) {
    like( $source, $expected_near{$label}, "the helper is called with the right arguments, adjacent to ${label}'s own distinguishing context (source-text check, not a parser - see comment above)" );
}

done_testing();
