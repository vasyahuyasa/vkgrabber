#!/usr/bin/perl

use strict;
use utf8;
use POSIX qw(strftime);
use Data::Dumper;
use LWP::UserAgent;
use JSON;
use Carp;
use FindBin;                   # locate this script
use lib "$FindBin::Bin/..";    # parent directory
use VkDb;
use feature 'state';           # статические переменные
use Try::Tiny;

my $vkdb;                      # Класс базы данных
my $postArray;                 # Массив из профилей и информацией по последнему сообщению поста
my $topicArray;                # Массив из профилей и информацией по последнему сообщению обсуждения
my $globalProfiles;            # Массив с настройками профилей
my $globalConfig;              # Конфиг из json

use constant {
	APIVER  => '5.50',
	APIURL  => 'https://api.vk.com/method/',
	BASEURL => 'https://vk.com/',
	CONFIG  => 'config.json',
	DEBUG   => 1
};

sub dbg {
	my ($text) = @_;

	print("$text\n") if DEBUG;
	return 1;
}

sub sendmail {
	my ($to, $message) = @_;

	return if !defined $to;

	dbg("Sending email to $to ...");

	my $subject = 'Найдена заявка!';
	open(my $mail, "|-", "/usr/sbin/sendmail -t");

	# Email Header
	print $mail "To: $to\n";
	print $mail "From: vkbot<noreply\@localhost.ru>\n";
	print $mail "Subject: $subject\n";
	print $mail "Content-Type: text/html; charset=\"utf-8\"\n\n";

	# Email Body
	print $mail $message;

	close($mail);
}

# Выполнить VK api метод
sub vk {
	my ($method, %parameters) = @_;

	state $ua;
	if (!defined($ua)) {
		$ua = LWP::UserAgent->new;
		$ua->timeout(5);
	}

	#my $ua  = LWP::UserAgent->new;
	my $url = URI->new(APIURL . $method);
	if (!exists $parameters{'v'}) {
		$parameters{'v'} = APIVER;
	}
	$url->query_form(%parameters);

	#sleep(1) if $reqs >= 5;
	my $res = $ua->get($url);

	my $code = $res->code;
	if ($code != 200) {
		dbg("LWP error code: $code");
		dbg(Dumper $res->decoded_content);
		return {};
	}

	my $content = $res->decoded_content;

	# Если ошибка при обработке json, не завершать программу
	my $hash = {};
	try {
		$hash = decode_json($content);
	}
	catch {
		print "$_\n";
		print "JSON: $content\n";
	};

	# результат хэш из элементов
	return $hash;
}

# проверить ответ от vk на наличие ошибок
sub haveErrors {
	my ($response) = @_;

	if (ref $response ne ref {}) {
		return 1;
	}

	my $result = 0;
	if (defined $response->{'error'}) {

		# вывести ошибку
		my $code = $response->{'error'}->{'error_code'};
		my $msg  = $response->{'error'}->{'error_msg'};
		print "Error #$code - $msg\n";
		print Dumper $response->{'error'};
		$result = 1;
	}
	elsif (!defined $response->{'response'}) {
		print "Not vk response";
		if (DEBUG) {
			print Dumper $response;
		}

		$result = 1;
	}
	return $result;
}

# получить полную информацию о странице
# $shortname - id или короткое имя страницы
sub getGroupInfo {
	my ($shortname) = @_;

	# сохраннёная информация о группах
	state $knownGroups = undef;

	# если уже известный id
	return $knownGroups->{$shortname} if defined $knownGroups->{$shortname};

	my %params = ('group_id' => $shortname);
	my $group = vk('groups.getById', %params);

	return if haveErrors($group);

	my $info;

	# если есть информация
	if (scalar(@{ $group->{'response'} })) {
		$info = $group->{'response'}[0];

		my $id          = $info->{'id'};
		my $screen_name = $info->{'screen_name'};

		$knownGroups->{$id}          = $info;
		$knownGroups->{$screen_name} = $info;
	}

	return $info;
}

# Получить id группы
sub getGroupId {
	my ($shortname) = @_;

	dbg("getGroupId name: $shortname");
	my $page = getGroupInfo($shortname);

	return 0 if !$page;
	return -$page->{'id'};
}

# получить информацию о обсуждении
sub getTopicInfo {
	my ($gid, $tid) = @_;

	# информация о обсуждениях
	state $knownTopics = undef;

	# если известен id
	return $knownTopics->{$gid}->{$tid} if defined $knownTopics->{$gid}->{$tid};

	my %params = (
		'group_id'  => $gid,
		'topic_ids' => $tid
	);
	my $response = vk('board.getTopics', %params);
	return if haveErrors($response);
	my $info;

	#если есть информация
	if (scalar(@{ $response->{'response'}->{'items'} })) {
		$info = $response->{'response'}->{'items'}[0];
		$knownTopics->{$gid}->{$tid} = $info;
	}
	return $info;
}

# Получить список последних записей на стене сообщества
# $gid - id сообщества, начмнается с -
# $count - количество постов для получения, по умолчанию 10
sub getGroupPosts {
	my ($gid, $count) = @_;

	dbg('getGroupPosts');
	$count = $count ? $count : 10;

	$gid = getGroupId($gid);
	my %params = ('owner_id' => $gid, 'count' => $count);
	my $r = vk('wall.get', %params);
	return $r;
}

# Получить список комментариев к посту
# $groupid - id группы
# $postid - id поста
# $startid - с этого id начинать выводить комментарии
sub getPostComments {
	my ($groupid, $postid, $startid) = @_;

	dbg('getPostComments');

	$startid = $startid ? $startid : 0;
	my %params = (
		'owner_id'         => $groupid,
		'post_id'          => $postid,
		'start_comment_id' => $startid,
		'extended'         => 1
	);
	my $comments = vk('wall.getComments', %params);
	return $comments;
}

# Получить комментарии обсуждения
# $gid - id группы
# $pid - id обсуждения
# $startid - возвращать комментарии начиная с указаного id
sub getTopicComments {
	my ($gid, $tid, $startid) = @_;

	dbg("getTopicComments gid: $gid, tid:$tid, startid:$startid");
	$startid = 0 if !defined $startid;
	my %params = (
		'group_id'         => $gid,
		'topic_id'         => $tid,
		'extended'         => 1,
		'start_comment_id' => $startid
	);

	my $comments = vk('board.getComments', %params);
	return $comments;
}

# определить тип ссылки topic или page или unknown
# $link - полная ссылка на ресурс
sub linkType {
	my ($link) = @_;

	my $type = 'unknown';
	if (index($link, 'vk.com/topic-') != -1) {
		$type = 'topic';
	}
	elsif (index($link, 'vk.com/') != -1) {
		$type = 'page';
	}
	return $type;
}

# Извечь короткое имя группы из ссылки
# $link - полная ссылка на группу vk
sub getPageName {
	my ($link) = @_;
	dbg("getPageName");

	$link =~ s/(.+)vk.com\///;
	dbg("pagename: $link");
	return $link;
}

# получить информацию о обсуждении
# link полная ссылка на обсуждение (http://vk.com/topic-16202769_32828846)
# return: $gid, $tid - id группы и обсуждения
sub getTopicId {
	my ($link) = @_;

	my ($gid, $tid) = $link =~ m/.*topic-(\d+)_(\d+).*$/;
	return ($gid, $tid);
}

# Получитьинформацию о последнем комментарии в посте
# $gid - id группы
# $pid - id поста
# count - общее кол-во. комментариев поста
sub getLastPostComment {
	my ($gid, $pid, $count) = @_;

	dbg("getLastPostComment gid:$gid pid:$pid count:$count");

	# если нет постов, то ничего не возвращать
	return if !$count;

	my %params = (
		'owner_id' => $gid,
		'post_id'  => $pid,
		'offset'   => $count - 1,
		'count'    => 1
	);
	my $comments = vk('wall.getComments', %params);
	return if haveErrors($comments);

	#print Dumper $comment;
	my $comment = $comments->{'response'}->{'items'}[0];
	return $comment;
}

# получитьинформацию о последнем комментарии в обсуждении
# $gid - id группы
# $tid - id поста
# count - общее кол-во. комментариев поста
sub getLastTopicComment {
	my ($gid, $tid, $count) = @_;

	dbg("getLastTopicComment gid: $gid tid: $tid count: $count");
	return if !$count;

	my %params = (
		'group_id' => $gid,
		'topic_id' => $tid,
		'offset'   => $count - 1,
		'count'    => 1
	);

	my $response = vk('board.getComments', %params);
	return if haveErrors($response);

	# если нет комментариев
	if ($response->{'response'}->{'count'} == 0) {
		return;
	}

	my $comment = $response->{'response'}->{'items'}[0];
	return $comment;
}

# Получить новые комментарии для поста
# $gid - idгруппы
# $pid -id поста
# $start -id комментария с которого начинать проверку новых постов
sub getNewPostComments {
	my ($gid, $pid, $start_id) = @_;

	dbg("getNewPostComments gid:$gid pid:$pid start_id:$start_id");
	my %params = (
		'owner_id'       => $gid,
		'post_id'        => $pid,
		'preview_length' => 0,
		'extended'       => 1
	);

	# если указан id последнего комментария, то получить список всех последующих
	if (defined $start_id) {
		$params{'start_comment_id'} = $start_id;
		$params{'offset'}           = 1;
	}

	my $response = vk('wall.getComments', %params);
	return $response;
}

sub getNewTopicComments {
	my ($gid, $tid, $startid) = @_;

	dbg("getTopicComments gid: $gid, tid:$tid, startid:$startid");
	my %params = (
		'group_id' => $gid,
		'topic_id' => $tid,
		'extended' => 1,
	);

	# если указан id последнего комментария, то получить список всех последующих
	if (defined $startid) {
		$params{'start_comment_id'} = $startid;
		$params{'offset'}           = 1;
	}

	my $response = vk('board.getComments', %params);
	return $response;
}

# Создать тело сообщения для отправки по почте
# $type - тип оповещения page или topic
# $gid - id группы
# $pid - id обсуждения или поста
# $comment - хэш массив с онформацией
sub createMailMessage {
	my ($type, $gid, $pid, $comment, $profile) = @_;

	# название группы
	$gid = abs($gid);
	my $group_info = getGroupInfo($gid);
	my ($group_name, $group_screen, $group_link);
	if ($group_info->{'name'}) {
		$group_name   = $group_info->{'name'};
		$group_screen = $group_info->{'screen_name'};
		$group_link   = "https://vk.com/$group_screen";
	}

	# ссылка на сообщение
	my $message_link;
	if ($type eq 'page') {

		# http://vk.com/wall-51812607_4228540?reply=4228548
		$message_link = "https://vk.com/wall-" . $gid . "_" . $pid . "?reply=" . $comment->{'id'};
	}
	elsif ($type eq 'topic') {

		#http://vk.com/topic-51812607_28045917?post=30
		$message_link = "https://vk.com/topic-" . $gid . "_" . $pid . "?post=" . $comment->{'id'};
	}

	# время поста
	my $date = $comment->{'date'};
	my ($sec, $min, $hour, $mday, $mon, $year, $wday, $yday, $isdst) = localtime($date);
	my $time_str = sprintf("%02d.%02d %02d:%02d", $mon + 1, $mday, $hour, $min);

	# обсуждение
	my $topic_title;
	my $topic_link;
	if ($type eq 'topic') {
		my $topic_info = getTopicInfo($gid, $pid);
		if (defined $topic_info->{'title'}) {
			$topic_title = $topic_info->{'title'};
			$topic_link  = "https://vk.com/topic-" . $gid . "_" . $pid;
		}
	}

	# провиль пользователся
	my $profile_name        = $profile->{'first_name'} . " " . $profile->{'last_name'};
	my $profile_screen_name = $profile->{'screen_name'};
	my $profile_link        = "<a href=\"https://vk.com/$profile_screen_name\">$profile_screen_name</a>";

	# текст письма
	my $text = "<p>Новое сообщение <a href=\"$message_link\">#" . $comment->{'id'} . "</a></p>";
	$text .= "<p><b>Время:</b> $time_str</p>";
	$text .= "<p><b>Группа:</b> <a href=\"$group_link\">$group_name</a></p>";

	if ($type eq 'topic') {
		$text .= "<p><b>Обсуждение:</b> <a href=\"$topic_link\">$topic_title</a></p>";
	}

	$text .= "<p><b>От:</b> $profile_name ($profile_link)</p>";
	$text .= "<p>" . $comment->{'text'} . "</p>";
	return $text;
}

# обработать комментарий и отослать уведомление на email
# $group - название конфигурации
# $gid - id группы
# $pid - id поста
# $comment - информация о комментарии
sub processNewComment {
	my ($group, $type, $gid, $pid, $comment, $profile) = @_;

	dbg("processNewComment group:$group type: $type gid:$gid pid:$pid ");

	my $date       = $comment->{'date'};
	my $comment_id = $comment->{'id'};
	my $text       = $comment->{'text'};

	# добавить информацию в БД
	#$vkdb->addComment($group, $type, $gid, $pid, $date, $comment_id, $text, $profile);

	# отправить email оповещение
	# если задано несколько email адресов
	my @emails = @{$globalProfiles->{$group}->{'emails'}};
	if (scalar(@emails)) {
		# отправить всем адресатам
		for my $email (@emails) {
			my $body = createMailMessage($type, $gid, $pid, $comment, $profile);
			sendmail($email, $body);
		}
	}
}

# Проверить появление новых комментариев на странице
# $group - профиль для которого проверяются новые сообщения
# $shortname - id или короткое имя группы
sub checkPageNewMessages {
	my ($group, $shortname) = @_;

	dbg("checkPageNewMessages group: $group shortname: $shortname");
	my $gid   = getGroupId($shortname);
	my $posts = getGroupPosts($shortname);

	# вернуться если есть ошибки
	return if haveErrors($posts);

	# если новая группа, то создать пустую запаись
	if (!defined $postArray->{$group}->{$gid}) {
		$postArray->{$group}->{$gid} = {};
	}

	#print Dumper $posts;
	#return;

	# проверить каждый пост на наличие новых комментариев
	for my $post (@{ $posts->{'response'}->{'items'} }) {
		my $pid      = $post->{'id'};
		my $start_id = undef;

		if (defined $postArray->{$group}->{$gid}->{$pid}) {

			# если пост уже в массиве, взять id последнего комментария
			$start_id = $postArray->{$group}->{$gid}->{$pid}->{'id'};
			dbg("Know post start_id: $start_id");
		}
		else {
			# занести пост в массив с последним комментарием, если он есть
			dbg("New post detected!");
			my $count = $post->{'comments'}->{'count'};
			my $newcomment = getLastPostComment($gid, $pid, $count);

			#print Dumper $newcomment;

			$postArray->{$group}->{$gid}->{$pid} = $newcomment;
			$start_id = $newcomment->{'id'};
		}

		# если не установлен последний комментарий
		if (!defined $postArray->{$group}->{$gid}->{$pid}) {
			next;
		}

		my $response = getNewPostComments($gid, $pid, $start_id);
		return if haveErrors($response);
		my ($newcoments, $profiles);

		if ($response) {
			$newcoments = $response->{'response'}->{'items'}    if defined $response->{'response'}->{'items'};
			$profiles   = $response->{'response'}->{'profiles'} if defined $response->{'response'}->{'profiles'};
		}

		# если есть новые комментарии
		if ($newcoments && scalar(@{$newcoments})) {
			for my $newcomment (@{$newcoments}) {

				# добавить комментарий в массив
				$postArray->{$group}->{$gid}->{$pid} = $newcomment;

				#получить профиль комментатора
				my $profile;
				if ($profiles && scalar(@{$profiles})) {
					for my $p (@{$profiles}) {
						if ($newcomment->{'from_id'} eq $p->{'id'}) {
							$profile = $p;
							last;
						}
					}
				}

				#обработать новый комментарий
				processNewComment($group, 'page', $gid, $pid, $newcomment, $profile);
			}
		}
	}
}

# Проверить новые сообщения в обсуждении
# group - id профиля
# gid - id группы
# tid - id обсуждения
sub checkTopicNewMessages {
	my ($group, $gid, $tid) = @_;

	dbg("checkTopicNewMessages group: $group shortname: $gid, topic: $tid");
	my $start_id = undef;

	# есть ли группа в массиве
	if (!defined $topicArray->{$group}->{$gid}) {
		$topicArray->{$group}->{$gid} = {};
	}

	# проверить есть ли обсуждение в массиве
	if (!defined $topicArray->{$group}->{$gid}->{$tid}) {

		# в конфиг добавленно новое обсуждение
		# получить информацию о числе комментариев в обсуждении
		dbg('В конфигурацию добавлено новое обсуждение для мониторинга');
		my %params = ('group_id' => $gid, 'topic_ids' => $tid);
		my $response = vk('board.getTopics', %params);
		return if haveErrors($response);
		my $count = $response->{'response'}->{'items'}[0]->{'comments'};
		my $lastcomment = getLastTopicComment($gid, $tid, $count);
		$topicArray->{$group}->{$gid}->{$tid} = $lastcomment;
	}

	# если не установлен последний комментарий
	if (!defined $topicArray->{$group}->{$gid}->{$tid}) {
		return;
	}

	# id последнего комментария в обсуждении
	$start_id = $topicArray->{$group}->{$gid}->{$tid}->{'id'};

	my $response = getNewTopicComments($gid, $tid, $start_id);

	return if haveErrors($response);

	my ($newcomments, $profiles);
	if ($response) {
		$newcomments = $response->{'response'}->{'items'}    if defined $response->{'response'}->{'items'};
		$profiles    = $response->{'response'}->{'profiles'} if defined $response->{'response'}->{'profiles'};
	}

	# если есть новые комментарии
	if ($newcomments && scalar(@{$newcomments})) {
		for my $newcomment (@{$newcomments}) {

			# добавить комментарий в массив
			$topicArray->{$group}->{$gid}->{$tid} = $newcomment;

			#получить профиль комментатора
			my $profile;
			if ($profiles && scalar(@{$profiles})) {
				for my $p (@{$profiles}) {
					if ($newcomment->{'from_id'} eq $p->{'id'}) {
						$profile = $p;
						last;
					}
				}
			}

			#обработать новый комментарий
			processNewComment($group, 'topic', $gid, $tid, $newcomment, $profile);
		}
	}
}

sub processGroup {
	my ($name) = @_;

	dbg("processGroup $name");

	# email для оповещения и массив ссылок для проверки
	my $profile = $globalProfiles->{$name};
	my $email   = $profile->{'email'};
	my @links   = @{ $profile->{'links'} };

	for my $link (@links) {
		my $type = linkType($link);
		if ($type eq 'page') {
			my $shortname = getPageName($link);
			checkPageNewMessages($name, $shortname);
		}
		elsif ($type eq 'topic') {
			my ($gid, $tid) = getTopicId($link);
			checkTopicNewMessages($name, $gid, $tid);
		}
	}
}

# обновить профили из бд
sub updateProfiles {
	$globalProfiles = $vkdb->getProfiles();
}

# становить соединение с БД
sub init {

	# считать конфиг
	my $str;
	my $fname = CONFIG;
	{
		local $/;
		open my $fh, '<', $fname or die "can't open config $fname: .$!";
		$str = <$fh>;
	}
	$globalConfig = decode_json($str);

	my $user     = $globalConfig->{'database'}->{'mysql'}->{'user'};
	my $password = $globalConfig->{'database'}->{'mysql'}->{'password'};
	my $database = $globalConfig->{'database'}->{'mysql'}->{'database'};
	my $server   = $globalConfig->{'database'}->{'mysql'}->{'server'};

	$vkdb = VkDb->new($user, $password, $database, $server);
}

sub main {
	init();
	my $delay = $globalConfig->{'settings'}->{'sleep'};
	while (1) {

		$globalProfiles = $vkdb->getProfiles();
		my @profile_names = keys %{$globalProfiles};
		for my $name (@profile_names) {
			my $group = $globalProfiles->{$name};
			processGroup($name, $group);
		}
		dbg("sleep... $delay");
		sleep($delay);
	}
}

main();

