use strict;
use warnings;
use v5.24;
use threads;
use threads::shared;
use Time::Local;
use DateTime;
use File::Basename;
use Cwd 'abs_path';
use Win32::API;
no warnings 'experimental';

# array of keywords to search for
our @keywords = ("rampage", "stun");

# path to log file
our $log_file = undef;
our $log_char = undef;
our $last_modified = undef;
our $start_time;
our %detected_logs :shared;
our %player_profiles :shared;
our $scan_thread;
our $sound_thread;

my $orange = "\e[38;5;208m";
my $green = "\e[38;5;10m";
my $red = "\e[38;5;9m";
my $reset = "\e[0m";

my $debug = 0;
my $scanning :shared = 0;

my @messages = (
    "Welcome to the EQ Sentinel.",
    "Commands:",
    "  ${orange}path${reset} [file path]: Set the log file path",
    "  ${orange}start${reset}: Start the scanner",
    "  ${orange}stop${reset}: Stop the scanner",
    "  ${orange}debug${reset}: Enter debug mode",
    "  ${orange}keywords add${reset} [keyword]: Add a keyword to search for",
    "  ${orange}keywords remove${reset} [keyword]: Remove a keyword from search list",
    "  ${orange}keywords${reset}: List all active keywords",
    "  ${orange}status${reset}: Print a status report.",
    "  ${orange}profiles${reset}: List all active player profiles",
    "  ${orange}profiles set${reset}: List all active player profiles and select one as active.",
    "  ${orange}menu${reset}: Show this menu",
    "  ${orange}exit${reset}: Close EQ Sentinel"
);

check_and_install_alsa();
menu(); #Show main menu



sub check_and_install_alsa {
    system("cpanm install Win32::API") == 0
    or die "Failed to install Win32::API: $?";
}

sub play_sound {
    my $selection = shift;
    # Get the directory of the script
    my $script_dir = dirname(abs_path($0));

    # Append the "Sounds" subdirectory to the script directory
    my $sounds_dir = "$script_dir/Sounds";

    # Declare the mciSendString function
    my $mciSendString = new Win32::API( "winmm", "mciSendStringA", 'PLLL', 'L' );

    # The file to play
    my $file = "";
    if ($selection eq "ding") {
        $file = "$sounds_dir/ding.mp3";
    } elsif ($selection eq "alarm") {
        $file = "$sounds_dir/alarm.mp3";
    } elsif ($selection eq "chime") {
        $file = "$sounds_dir/chime.mp3";
    } else {
        print "Invalid sound selection: $selection";
        return;
    }

    # Send the command to open the file
    $mciSendString->Call( "open \"$file\" type mpegvideo alias my_file", 0, 0, 0 );

    # Send the command to play the file
    $mciSendString->Call( "play my_file", 0, 0, 0 );

    # Wait for the file to finish playing
    my $status = 0;
    $mciSendString->Call("status my_file mode", $status, 1024, 0);
    sleep(2);

    # Close the file
    $mciSendString->Call( "close my_file", 0, 0, 0 );
}

sub menu {
    print join("\n", @messages, "\n");
}


sub detectChar {
    my ($path) = @_;
    $path =~ /eqlog_(.*?)_/;
    return $1;
}

sub save_keywords {
    open(my $config_file, ">", "keywords.config") or do {
        print "Failed to save keywords to config file.\n";
        return;
    };
    close $config_file;
    return;
}

sub load_keywords {
    open(my $config_file, "<", "keywords.config") or do {
    print "No saved keywords detected.\n";
    return;
    };
    @keywords = ();
    while (my $line = <$config_file>) {
        chomp $line;
        push @keywords, $line;
    }
    close $config_file;
    return;
}


sub load_profiles {
    open(my $config_file, "<", "profiles.config") or do {
        print "No saved player profiles detected.\n";
        return;
    };
    while (my $line = <$config_file>) {
        chomp $line;
        my ($name, $path) = ($line =~ /([^:]*):(.*)/);
        $player_profiles{$name} = $path;
    }
    close $config_file;
}


sub save_profiles {
    open(my $config_file, ">", "profiles.config") or die "Could not open file: $!";
    
    while( my($name, $path) = each %player_profiles ) {
      print $config_file $name . ":" . $player_profiles{$name} . "\n";
      print("Saved Profile: " . $name . ":" . $player_profiles{$name} . "\n") if $debug;
    }
    close $config_file;
    return;
}

sub load_selected_profile {
    open(my $config_file, "<", "selected_profile.config") or do {
        print "No selected profiles detected.\n";
        return;
    };
    my $line = <$config_file>;
    if($line){
        chomp $line;
        ($log_char, $log_file) = ($line =~ /([^:]*):(.*)/);
        close $config_file;
    }
    else{
        close $config_file;
    }
    return;
}

sub save_selected_profile {
    if(defined $log_char && defined $log_file){
        open(my $config_file, ">", "selected_profile.config") or die "Could not open file: $!";
        if (defined $player_profiles{$log_char}) {
            print $config_file "$log_char:" . $player_profiles{$log_char};
        } else {
            print "Save selected profile abandoned for $log_char($log_file)...\n";
        }
        close $config_file;
    }
}

sub add_player_profile {
    my ($name, $path) = @_;
    if (!exists $player_profiles{$name}){
        $player_profiles{$name} = $path;
        save_profiles();
    } else {
        print "Error: Profile with name '$name' already exists.\n";
    }
    return;
}


sub showKeywords() {
    print "Active keywords: \n";
    foreach my $word (@keywords) {
        print " - $word\n";
    }
}

sub display_profiles {
    my $size = keys %player_profiles;
    print("Number of saved profiles: $size\n");
    my $index = 1; # counter for the profile number
    if(%player_profiles){
        print "--- List of Selected Profiles ---\n";
        while(my($name, $path) = each %player_profiles){
            my $indicator = "$green <------Active$reset";
            if (not ($name eq $log_char)) {
                $indicator = "";
            } 
            print $green . $index . "." . $reset . " Profile name: " . $name . ", Profile path: " . $path . "$indicator" . "\n";
            $index++;
        }
    }else{
        print "No saved player profiles detected.\n";
    }
}


sub RestartScanner() {
    if (!$log_file) {
        print "Error: Log file path not set. Please set log file path with 'path' command before starting.\n";
    } else {
        if ($scanning) {
            my $stopText = "Stopping current scanning...\n";
            print "$red$stopText$reset";
            $scanning = 0;
            # Wait for previous scan thread to finish
            $scan_thread->join();
        }
        save_profiles();
        save_selected_profile();
        my $startText = "Restarting scanner...\n";
        print "$green$startText$reset";
        $scanning = 1;
        %detected_logs = ();
        my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
        my $startYear = $year + 1900; # year is returned as the number of years since 1900
        my $startMonth = $mon + 1; # month is returned as a number between 0 and 11
        $start_time = DateTime->new(year => $startYear, month => $startMonth, day => $mday, hour => $hour, minute => $min, second => $sec);
        print "Scan start time set at: $start_time\n" if $debug;
        $scan_thread = threads->create(\&scan_log, $log_file, $last_modified);
    }
}

sub handle_set_profile {
    # check if there are any player profiles available
    if(%player_profiles) {
        print "--- Available Player Profiles ---\n";
        my $i = 1;
        # display a numbered list of the available player profiles
        my $indicator = "$green <------Active$reset";
        my $modifier = "";
        while(my($name, $path) = each %player_profiles) {
            if ($name eq $log_char) {
                $modifier = $indicator;
            } 
            print $i . ". " . $name . " - " . $path . "$modifier\n";
            $modifier = "";
            $i++;
        }
        # prompt the user to select a profile number
        print "Enter the number corresponding to the profile you wish to load: ";
        my $profile_num = <STDIN>;
        chomp $profile_num;
        # check if the user entered a valid profile number
        if($profile_num > 0 && $profile_num <= scalar keys %player_profiles) {
            my $i = 1;
            while(my($name, $path) = each %player_profiles) {
                if($i == $profile_num) {
                    # set the selected profile
                    $log_char = $name;
                    $log_file = $path;
                    save_selected_profile();
                    print "Profile '$name' has been set as the selected profile.\n";
                    last;
                }
                $i++;
            }
        } else {
            print "Invalid profile number. Please enter a valid number corresponding to a profile from the list.\n";
        }
    } else {
        print "No player profiles available.\n";
    }
}



sub main() {

    load_profiles();
    load_selected_profile();
    load_keywords();

    while (1) {
        my $input = lc(<STDIN>);
        chomp $input;
        if ($input =~ /^path (.*)/) {
            $log_file = $1;
            $log_char = detectChar($log_file);
            add_player_profile($log_char, $log_file);
            if (-e $log_file) {
                $last_modified = (stat $log_file)[9];
                print "Log file path set to $log_file\n";
            } else {
                print "Error: Log file $log_file does not exist.\n";
                $log_file = undef;
            }
        } elsif ($input eq "profiles") {
            display_profiles();
        } elsif ($input eq "profiles set") {
            handle_set_profile();
        } elsif ($input eq "profiles clear") {
           %player_profiles = ();
            print "All player profiles have been cleared.\n";
            save_profiles();
        } elsif ($input eq "start") {
            if (!$log_file) {
                print "Error: Log file path not set. Please set log file path with 'path' command before starting.\n";
            } else {
                if (!$scanning) {
                    my $startText = "Scanning started\n";
                    print "$green$startText$reset";
                    $scanning = 1;
                    %detected_logs = ();
                    my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
                    my $startYear = $year + 1900; # year is returned as the number of years since 1900
                    my $startMonth = $mon + 1; # month is returned as a number between 0 and 11

                    $start_time = DateTime->new(year => $startYear, month => $startMonth, day => $mday, hour => $hour, minute => $min, second => $sec);

                    print "Scan start time set at: $start_time\n" if $debug;
                    $scan_thread = threads->create(\&scan_log, $log_file, $last_modified);
                } else {
                    print "Scanning already in progress\n" if $debug;
                }
            }
        } elsif ($input eq "stop") {
            my $stopText = "Scanning stopped\n";
            print "$red$stopText$reset";
            $scanning = 0;
        } elsif ($input eq "debug") {
            $debug = !$debug;
            print "Debugging is ".($debug ? "on" : "off")."\n"
        } elsif ($input =~ /^keywords add (.*)/) {
            push @keywords, $1;
            print "Keyword '$1' added to search list.\n";
            save_keywords();
            if ($scanning) {
                RestartScanner();
            }
        } elsif ($input =~ /^keywords remove (.*)/) {
            my $word = $1;
            my $index = first_index { $_ eq $word } @keywords;
            if(defined $index) {
                splice @keywords, $index, 1;
                print "Keyword '$word' removed from search list.\n";
                save_keywords();
                if ($scanning) {
                    RestartScanner();
                }
            } else {
                print "Error: '$word' not found in search list.\n";
            }
        } elsif ($input eq "keywords") {
            showKeywords();
        } elsif ($input eq "status") {
            if (!defined($log_file)) {
                print "Log file path not set.\n";
            } else {
                print "Log file path: $log_file\n";
                if ($scanning) {
                    print "Scanner status:$green Running$reset\n";
                } else {
                    print "Scanner status:$red Stopped$reset\n";
                }
            }
            print "Search list keywords: @keywords\n";
            print "Debugging:".($debug ? "$green Enabled$reset" : "$red Disabled$reset")."\n"
        } elsif ($input eq "menu") {
            menu(); # Show main menu
        } elsif ($input eq "exit") {
            $scanning = 0;
            exit;
        } else {
        print "Invalid command. Please enter 'path', 'start', 'stop', 'add', 'remove' or 'status'\n";
        }
        print "-----------------------------------------\n";
    }
}

sub scan_log {
    our ($log_file, $last_modified) = @_;
    if (not $last_modified) {
        $last_modified = 0;
    }
    # Loop while the scanning variable is true
    while ($scanning) {
        # Get the current modification time of the log file
        my $current_modified = (stat $log_file)[9];
        if (not $current_modified) {
            $current_modified = 0;
        }
        # Check if the current modification time is greater than the last recorded modification time
        if($current_modified > $last_modified) {
            # Open the log file for reading
            open(my $fh, "<", $log_file) or die "Error opening $log_file: $!";
            # Loop through each line of the log file
            while (my $line = readline $fh) {
                # Loop through each keyword
                for my $keyword (@keywords) {
                    # Check if the keyword appears in the line
                    if ($line =~ /(?i)$keyword/) {
                        # Check if the line has not already been detected
                        if (!exists $detected_logs{$line}) {
                            # Mark the line as detected
                            $detected_logs{$line} = 1;
                            # Call the KeywordDetected function to handle the keyword trigger action
                            KeywordDetected($line, $keyword);
                        }
                    }
                }
            }
            # Update the last recorded modification time
            $last_modified = $current_modified;
            # Close the log file
            close $fh;
        }
    }
}

sub KeywordDetected {
    my ($line, $keyword) = @_;
    # Extracting the date and time from the log line using regular expressions
    my ($log_day, $log_mon, $log_dayOfMonth, $log_hour, $log_min, $log_sec, $log_year) = $line =~ /\[(.*?) (.*?) (.*?) (.*?):(.*?):(.*?) (.*?)\]/;
    # Convert the month and day strings to numerical values
    $log_mon = ConvertMonth($log_mon);
    $log_day = ConvertDay($log_day);
    # Print the extracted date and time parts if the debug flag is set
    print "(LogDay:$log_day, LogMonth:$log_mon, LogDayofMonth:$log_dayOfMonth, LogHour:$log_hour, LogMin:$log_min, LogSec:$log_sec, LogYear:$log_year)\n" if $debug;
    # Create a DateTime object from the extracted date and time parts
    my $log_time = DateTime->new(year => $log_year, month => $log_mon, day => $log_dayOfMonth, hour => $log_hour, minute => $log_min, second => $log_sec);

    # Print the log time and start time if the debug flag is set
    print "LogTime:$log_time, $start_time\n" if $debug;
    # Check if the log time is defined and greater than or equal to the start time
    if (defined($log_time) && ($log_time >= $start_time)) {
        # Place code below to handle keyword trigger actions
        # Print a message indicating that the keyword has been detected in the line
        my $green_line = $line;
        $green_line =~ s/($keyword)/$green$1$reset/g;
        print $log_time->strftime("[%Y-%m-%d %H:%M:%S]"), "Keyword [$green$keyword$reset] detected in line: $green_line\n";
        $sound_thread = threads->create(\&play_sound, "ding")->detach();
    }
}



sub ConvertMonth {
	my $month = lc(shift);
	
	if ($month eq "jan") { return 1; }
	elsif ($month eq "feb") { return 2; }
	elsif ($month eq "mar") { return 3; }
	elsif ($month eq "apr") { return 4; }
	elsif ($month eq "may") { return 5; }
	elsif ($month eq "jun") { return 6; }
	elsif ($month eq "jul") { return 7; }
	elsif ($month eq "aug") { return 8; }
	elsif ($month eq "sep") { return 9; }
	elsif ($month eq "oct") { return 10; }
	elsif ($month eq "nov") { return 11; }
	elsif ($month eq "dec") { return 12; }
	else { return 0; }
}

sub ConvertDay {
	my $day = lc(shift);
	
	given ($day) {
		when ("mon") { return 1; }
		when ("tue") { return 2; }
		when ("wed") { return 3; }
		when ("thu") { return 4; }
		when ("fri") { return 5; }
		when ("sat") { return 6; }
		when ("sun") { return 7; }
		default { return 0; }
	}
}

main(); #Main sub call

END {
    $scanning = 0;
    print("${red}Exiting EQSentinal...${reset}\n");
    print("${orange}Saving settings...${reset}\n");
    sleep(1);
    print("${green}Settings Saved!${reset}\n");
    if ($scan_thread and $scan_thread->is_joinable()) {
        $scan_thread->join();
    }
    if ($sound_thread and $sound_thread->is_joinable()) {
        $sound_thread->join();
    }
    save_profiles();
    save_selected_profile();
    save_keywords();
}
