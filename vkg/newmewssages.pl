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

my $ua;                        # BDI::UserAgent
my $vkdb;                      # Класс базы данных
my $config;                    # конфигурация
my %groups;                    # Список групп с информацией о последних постах

#groups {
#	gid: {
#		pid: { comment },
#		pid2: { comment }
#	},
#	gid2: {
#		...
#	}
#}

use constant {
	APIVER  => '5.50',
	APIURL  => 'https://api.vk.com/method/',
	BASEURL => 'https://vk.com/',
	CONFIG  => 'config.json',
	DEBUG   => 1
};

sub dbg {
	my ($text) = @_;

	if (DEBUG) {

		print("$text\n");
	}
	return 1;
}

sub getConfig {
	my ($fname) = @_;

	dbg('getConfig');

	my $str;
	my $cfg;
	$fname = CONFIG if !defined $fname;
	{
		local $/;
		open my $fh, '<', $fname or die "can't open config $fname: .$!";
		$str = <$fh>;
	}

	return decode_json($str);
}

sub sendmail {
	my ($to, $message) = @_;

	dbg("Sending email to $to ...");

	my $subject = 'Новое сообщение в vk.';
	open(my $mail, "|-", "/usr/sbin/sendmail -t");

	# Email Header
	print $mail "To: $to\n";
	print $mail "Subject: $subject\n";
	print $mail "Content-type: text/html\n\n";

	# Email Body
	print $mail $message;

	close($mail);
}

# Выполнить VK api метод
sub vk {
	my ($method, %parameters) = @_;

	if (!defined($ua)) {
		$ua = LWP::UserAgent->new;
		$ua->timeout(10);
	}

	#my $ua  = LWP::UserAgent->new;
	my $url = URI->new(APIURL . $method);
	if (!exists $parameters{'v'}) {
		$parameters{'v'} = APIVER;
	}
	$url->query_form(%parameters);

	#sleep(1) if $reqs >= 5;
	my $res = $ua->get($url);

	return {} if $res->code != 200;

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
		print "Not vk response\n";
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
	my $s = scalar @{ $group->{'response'} };
	if (scalar(@{ $group->{'response'} })) {
		$info = $group->{'response'}[0];

		my $id          = $info->{'id'};
		my $screen_name = $info->{'screen_name'};

		$knownGroups->{ -$id } = $info;
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

# Получить список записей на стене сообщества
sub getGroupPosts {
	my ($gid) = @_;

	dbg('getGroupPosts');
	my $count = $config->{'settings'}->{'count'};

	$gid = getGroupId($gid);

	my %params = ('owner_id' => $gid, 'count' => $count);
	my $r = vk('wall.get', %params);
	return $r;
}

# Вывести список постов
sub printPosts {
	my ($posts, $group) = @_;

	dbg('printPosts');
	$group = 0 if !defined $group;
	my $count = 1;
	foreach my $post (@{ $posts->{'response'}->{'items'} }) {

		#print Dumper $post;

		print $count++ . "\n";

		# обрабатывать только посты
		if (ref($post) eq 'HASH') {
			my $date    = $post->{'date'};
			my $id      = $post->{'id'};
			my $strtime = strftime("%a %b %e %H:%M:%S %Y", localtime($date));
			print "#$id ===$strtime===\n";
			print $post->{'text'} . "\ncomments: " . $post->{'comments'}->{'count'} . "\n\n";
			if ($group) {
				my $comments = getPostComments($group, $id);
			}
		}
	}
	return;
}

# Получить список комментариев к посту
sub getPostComments {
	my ($groupid, $postid, $startid) = @_;

	dbg('getPostComments');

	$startid = 0 if !defined $startid;
	my %params = {
		'owner_id'         => $groupid,
		'post_id'          => $postid,
		'start_comment_id' => $startid,
		'extended'         => 1
	};
	my $comments = vk('wall.getComments', %params);
	return $comments;
}

# определить тип ссылки topic или page или unknown
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

sub getPageName {
	my ($link) = @_;
	dbg("getPageName");

	$link =~ s/(.+)vk.com\///;
	dbg("pagename: $link");
	return $link;
}

# получитьинформацию о последнем комментарии в посте
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

# Получить новые комментарии для поста
# $gid - idгруппы
# $pid -id поста
# $start -id комментария с которого начинать проверку новых постов
sub getNewPostComments {
	my ($gid, $pid, $start_id) = @_;

	dbg("getNewPostComments gid:$gid pid:$pid start_id:$start_id");

	if ($gid > 0) {
		dbg("WARNING: id группы больше 0");
		return;
	}

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

	return [] if haveErrors($response);
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
	my $group_info = getGroupInfo($gid);
	my ($group_name, $group_screen);
	if ($group_info->{'name'}) {
		$group_name   = $group_info->{'name'};
		$group_screen = $group_info->{'screen_name'};
	}

	my $text = "<p>Новое сообщение в группе <a href=\"https://vk.com/$group_screen\">$group_name</a></p>";
	if ($type eq 'topic') {
		$text .= "<p>В обсуждении <a href=\"$pid\">$pid</a></p>";
	}

	# имя пользователя
	my $name;
	if ($profile) {
		my $screen_name = $profile->{'screen_name'};
		$text .= '<p>От: <b>' . $profile->{'first_name'} . ' ' . $profile->{'last_name'} . "</b> (<a href=\"https://vk.com/$screen_name\">$screen_name</a>)</p>";
	}
	$text .= "<p>" . $comment->{'text'} . "</p>";
	return $text;
}

# обработать комментарий и отослать уведомление на email
# $group - название конфигурации
# $gid - id группы
# $pid - id поста
# $comment - информация о комментарии
sub processNewComment {
	my ($group, $gid, $pid, $comment, $profile) = @_;

	dbg("processNewComment group:$group gid:$gid pid:$pid ");

	my $date       = $comment->{'date'};
	my $comment_id = $comment->{'id'};
	my $text       = $comment->{'text'};

	# добавить информацию в БД
	$vkdb->addComment($group, "page", $gid, $pid, $date, $comment_id, $text);

	# отправить email оповещение
	my $email = $config->{'groups'}->{$group}->{'email'};
	my $body = createMailMessage('page', $gid, $pid, $comment, $profile);

	sendmail($email, $body);
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

	#print Dumper $posts;
	#return;

	# проверить каждый пост на наличие новых комментариев
	for my $post (@{ $posts->{'response'}->{'items'} }) {
		my $id       = $post->{'id'};
		my $start_id = undef;

		if (defined $groups{$group}{$gid}{$id}) {

			# если пост уже в массиве
			$start_id = $groups{$group}{$gid}{$id}->{'id'};
			dbg("SATRT_ID: $start_id");
		}
		else {
			# занести пост в массив
			dbg("New post detected!");
			$groups{$group}{$gid}{$id} = undef;
		}

		my $response = getNewPostComments($gid, $id, $start_id);

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
				$groups{$group}{$gid}{$id} = $newcomment;

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
				processNewComment($group, $gid, $id, $newcomment, $profile);
			}
		}

		my $count = $post->{'comments'}->{'count'};
	}
}

sub processGroup {
	my ($name, $cfg) = @_;

	dbg("processGroup $name");

	# email для оповещения и массив ссылок для проверки
	my $email = $cfg->{'email'};
	my @links = @{ $cfg->{'links'} };

	for my $link (@links) {
		my $type = linkType($link);
		if ($type eq 'page') {
			my $shortname = getPageName($link);
			checkPageNewMessages($name, $shortname);
		}
		elsif ($type eq 'topic') {
			dbg("TODO: check topic new messages");
		}
	}
}

# Проверяет указан ли ключ --first-run
sub isFirstRun {
	my $result = 0;

	for my $arg (@ARGV) {
		if ($arg eq '--first-run') {
			$result = 1;
			last;
		}
	}
	return $result;
}

# инициализация конфигурации и информации о постах
sub init {

	my $firstrun = isFirstRun();

	# загрузка конфигурации из JSON
	$config = getConfig(CONFIG);
	my $user     = $config->{'database'}->{'mysql'}->{'user'};
	my $password = $config->{'database'}->{'mysql'}->{'password'};
	my $database = $config->{'database'}->{'mysql'}->{'database'};
	my $server   = $config->{'database'}->{'mysql'}->{'server'};
	my $count    = $config->{'settings'}->{'count'};
	my @profiles = keys %{ $config->{'groups'} };

	# если есть данные для мониторинга
	# создань оединение с БД
	if (scalar(@profiles)) {
		$vkdb = VkDb->new($user, $password, $database, $server);
		for my $profile (@profiles) {

			$groups{$profile} = {};
			my @links = @{ $config->{'groups'}->{$profile}->{'links'} };
			for my $link (@links) {
				my $type = linkType($link);

				if ($type eq 'page') {
					my $pagename = getPageName($link);
					my $gid      = getGroupId($pagename);

					$groups{$profile}{$gid} = {};

					my %params = (
						'owner_id' => $gid,
						'count'    => $count
					);
					my $posts = vk('wall.get', %params);

					return if haveErrors($posts);

					# добавить пост и информацию о последнем комментарии из бд
					for my $post (@{ $posts->{'response'}->{'items'} }) {

						my $pid     = $post->{'id'};
						my $comment = {};

						# если первый запуск, то добавить в массимв информацию опоследнем посте из VK
						if ($firstrun) {
							my $count = $post->{'comments'}->{'count'};
							$comment = getLastPostComment($gid, $pid, $count);
							print $comment->{'text'} . "\n";
						}
						else {
							# добавить информацию из БД
							my $lastcomment = $vkdb->getLastComment('page', $gid, $pid);
							if ($lastcomment) {
								$comment = {
									'id'   => $lastcomment->{'comment_id'},
									'date' => $lastcomment->{'date'},
									'text' => $lastcomment->{'text'}
								};
								dbg("Last vomment from DB pid: $pid");
								print Dumper $comment;
							}
						}

						# если получен известный последний комментарий

						$groups{$profile}{$gid}{$pid} = $comment;
					}
				}
				elsif ($type eq 'topic') {

				}
			}
		}
	}
	else {
		die "Нет ни одного профиля для мониторинга";
	}

	# считать информацию о постах из БД
}

sub main {
	init();

	#dbg("%groups:");
	#print Dumper \%groups;
	#return;

	my $delay    = $config->{'settings'}->{'sleep'};
	my @profiles = keys %{ $config->{'groups'} };
	while (1) {
		for my $profile (@profiles) {
			my $group = $config->{'groups'}->{$profile};
			processGroup($profile, $group);
		}

		# жать delay сек
		sleep($delay);
	}

	return;
}

#binmode(STDOUT, ':utf8');
main();
