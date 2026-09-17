use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib", "$Bin/lib";

# TGT-290 (found via a user-requested comprehensive bug/improvement sweep,
# 2026-09-17): the shared multipart boundary generator used by send_voice,
# send_photo, and send_document (via _send_file) previously had only
# 'D2TGBoundary' . int(rand(1e9)) . time - about 30 bits of entropy. A file
# whose raw bytes happen to contain that string would corrupt the upload.
# This test asserts the boundary now carries far more entropy (128 bits,
# 32 hex characters) so an accidental real-world collision is
# cryptographically improbable instead of merely improbable.

require D2TG::Telegram;

ok( D2TG::Telegram->can('_generate_boundary'), 'D2TG::Telegram owns a shared _generate_boundary helper' );

{
    my $boundary = D2TG::Telegram::_generate_boundary();
    like( $boundary, qr/^D2TGBoundary[0-9a-f]{32}\d+$/, 'boundary carries a 128-bit (32 hex char) high-entropy segment, not a small-range rand()' );
}

{
    # Regression: two real (non-mocked) calls should essentially never collide.
    my $b1 = D2TG::Telegram::_generate_boundary();
    my $b2 = D2TG::Telegram::_generate_boundary();
    isnt( $b1, $b2, 'two real boundary generations are not identical' );
}

done_testing();
