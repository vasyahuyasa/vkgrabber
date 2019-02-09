#!/usr/bin/perl

# отправка сообщения на указаный адрес
sub sendmail {
        my ($to, $message) = @_;

        return if !defined $to;

        my $subject = 'Найдена заявка!';
        open(my $mail, "|-", "/usr/sbin/sendmail -t");
	#open(my $mail, ">test.txt");
        # Email Header
        print $mail "to: $to\n";
        print $mail "from: vkbot<noreply\@localhost.ru>\n";
        print $mail "subject: $subject\n";
        print $mail "Content-Type: text/html; charset=\"utf-8\"\n\n";

        # Email Body
        print $mail $message;

        close($mail);
}

sendmail("localhost\@localhost.com", "Сообщениеовое сообщение\n");
