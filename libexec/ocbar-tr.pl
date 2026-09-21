#!/usr/bin/perl
# Английский текст сообщения клиента по каталогу шаблонов.
#   ocbar-tr.pl <каталог.tsv> <сообщение>
# Каталог: «русский<TAB>английский», {} — подстановка, в переводе можно {1},
# {2}… если порядок другой. Подходит шаблон, совпавший со всей строкой;
# из нескольких — с самой длинной неизменной частью. Не нашлось — сообщение
# как есть: лучше русская строка, чем пустая.
use strict;
use warnings;
binmode STDOUT, ':encoding(UTF-8)';
my ($table, $msg) = @ARGV;
$msg = '' unless defined $msg;
utf8::decode($msg);
my @rules;
if (defined $table && open(my $fh, '<:encoding(UTF-8)', $table)) {
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^#/ || index($line, "\t") < 0;
        my ($ru, $en) = split /\t/, $line, 2;
        my @parts = split /\{\}/, $ru, -1;
        my $re = join '(.*)', map { quotemeta } @parts;
        push @rules, [qr/^$re$/s, $en, length(join '', @parts), scalar(@parts) - 1];
    }
    close $fh;
}
for my $r (sort { $b->[2] <=> $a->[2] } @rules) {
    my ($re, $en, undef, $n) = @$r;
    my @cap = $msg =~ $re or next;
    @cap = () if $n == 0;
    my $i = 0;
    if ($en =~ /\{\d+\}/) {
        $en =~ s/\{(\d+)\}/defined $cap[$1 - 1] ? $cap[$1 - 1] : ''/ge;
    } else {
        $en =~ s/\{\}/defined $cap[$i] ? $cap[$i++] : ''/ge;
    }
    print $en;
    exit 0;
}
print $msg;
