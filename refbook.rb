require 'sinatra'
require 'json'
require 'tilt/sass'
require 'parse-ruby-client'
require 'tilt/haml'
require 'sinatra/flash'
require 'pp'
require 'time'
require 'mail'
require 'rack-google-analytics'
require 'uri'
require 'open-uri'
require 'domainatrix'
require 'httparty'

configure do
  if settings.development?
    # this is so we can test on multiple local computers
    set :bind, '0.0.0.0'
    # foreman output
    # $stdout.sync = true
    require 'dotenv'
    Dotenv.load
  end

  enable :sessions

  set :session_secret, 'this_is_secret'
  # TODO: this really needs to be redone
  set :region_hash, {
    "Argentina" => "AAQ",
    "Australia" => "AUST",
    "Austria" => "QA",
    "Belgium" => "BQF",
    "Brazil" => "ABQ",
    "Canada" => "CANA",
    "Catalonia" => "AQC",
    "France" => "FQF",
    "Germany" => "DQB",
    "Italy" => "ITAL",
    "Mexico" => "MEX",
    "Netherlands" => "QNL",
    "Norway" => "NORW",
    "Poland" => "PLQ",
    "Spain" => "AQE",
    "Turkey" => "QD",
    "United Kingdom" => "QUK",
    "United States" => "USQ",
    "Other" => "OTHR",
    "All Regions" => "ALL"
  }
  set :affiliate, ["QUK", "AUST", "CANA", "ITAL", "NORW", "BQF", "QNL", "AQC"]
  set :region_names, settings.region_hash.keys[0..-2].sort
  set :region_codes, settings.region_names.map{|r| settings.region_hash[r]}
  # TIME BETWEEN ATTEMPTS
  # 604800 sec = 1 week
  set :waiting, 604800
  set :test_names, {ass: "Assistant", snitch: "Snitch", head: "Head", sample: "Sample"}
  set :updated_at, Time.now.utc
  set :time_string, '%e %B, %l:%M%P'
  # world clock string format
  set :wc_string, '%Y%m%dT%H%M'

  set :text_hash, JSON.parse(File.read('text.json'))
  set :layout_hash, JSON.parse(File.read('layout.json'))

  set :killed, false

  set :client, Parse.create({
    application_id: ENV['REFBOOK_PARSE_APP_ID'],
    master_key: ENV['REFBOOK_PARSE_API_KEY'],
    host: ENV['PARSE_HOST'],
    quiet: true
  })


  Mail.defaults do
    delivery_method :smtp, {
      :address   => "smtp.sendgrid.net",
      :port      => 587,
      :domain    => "refdevelopment.com",
      :user_name => ENV['SENDGRID_USERNAME'],
      :password  => ENV['SENDGRID_PASSWORD'],
      :authentication => 'plain',
      :enable_starttls_auto => true
    }
  end

  use Rack::GoogleAnalytics, :tracker => 'UA-42341849-2'
end

# helpers

# returns true if and only if the user is logged in
def logged_in?
  !session[:user].nil?
end

def admin?
  logged_in? && session[:user]['admin']
end

def paid?
  logged_in? && session[:user]['paid']
end

def affiliate?
  logged_in? && session[:user]['region'] != 'OTHR'
end
# gets the nice name from the key
# passing "USMW" returns "US Midwest"
# I don't love this system and may redo it
def reg_reverse(reg)
  settings.region_hash.select do |k, v|
    v == reg
  end.keys.first
end

# given a (parse) person object, returns their full name
def name_maker(person)
  "#{person['firstName']} #{person['lastName']}"
end

# this fetches a raw Parse object
# to save it to the session, tack on .to_h
def pull_user(id=nil)
  uid = id || session[:user]['objectId']
  settings.client.query("_User").eq("objectId", uid).get.first
end

# this takes the current session (theoretically with edits), saves it,
# and stores it back in the session. If you're not changing anything, safer
# to use #pull_user
def refresh_session!
  u = settings.client.object('_User', session[:user])
  session[:user] = u.save.to_h
end

# originally created to ease the transition between js bools and
# ruby bools, I'm not sure if I need it anymore
def to_bool(str)
  str.downcase == 'true' || str == '1'
end

def validate(key, region)
  #re-format just in case
  if key == '' || key.nil?
    return false
  end

  key.gsub!('-','')
  key.strip!

  # basically any 16 digit number. it's fine.
  return key.size == 16

  # if keys[region].include?(key)
  #   keys[region].delete key
  #   settings.keys.save(keys)
  #   puts "JUST USED KEY #{key}"
  #   return true
  # else
  #   puts "FAILED ON KEY #{key}"
  #   return false || 1 == 1
  # end
end

def sym_to_bool(b)
  b == :t
end

# what the heck did I write?
# you can pass in a hash with any of 3 options
# path: to mancually specify the route name
# layout: whether or not to render with a layout
# old: whether or not it uses the old haml format. Will depreciate later.
def display(args = {})
  pp args unless settings.test?
  path = args[:path] || request.path_info[1..-1].chomp('/')
  args[:layout] ||= :t
  # old is default to prevent breaking, this will change eventually
  args[:old] ||= :t
  args[:alt] ||= :f

  if sym_to_bool(args[:alt])
    @alt_text = settings.text_hash[path.to_s][@lang]
  else
    if !sym_to_bool(args[:old])
      # pp 'asdf',settings.text_hash
      @text = settings.text_hash[path.to_s][@lang]
    else
      @text = {}
    end
  end

  # pp @text

  haml path.to_sym, layout: sym_to_bool(args[:layout])
end

# EMAIL FUNCTIONS #

# For whatever reason, we need the mail gem in it's own little function
# this is just for test results, could add other message stuff

# on pass, shows testing page for other opportunities. On fail, shows link to test you failed for cooldown timer
def email_results(email, pass, test)
  tests = {ass: "Assistant", snitch: "Snitch", head: "Head", sample: "Sample"}
  Mail.deliver do
    to email
    from 'IRDP <irdp.rdt@gmail.com>'
    subject 'Referee Test Results'
    html_part do
      body "Hey there!<br><br>The IRDP has received and recorded your results for the #{tests[test]} Referee Test. You can see your #{pass ? 'other testing opportunities' : 'cooldown timer'} on the <a href=\"http://refdevelopment.com/testing/#{pass ? '' : test}\">testing page</a>.<br><br>Thank you for choosing the International Referee Development Program for your referee training needs.<br><br>Until next time,<br><br>~the IRDP<br><br>"
    end
  end
end

# def register_purchase(text)
#   Mail.deliver do
#     to "trigger@recipe.ifttt.com"
#     from 'irdp.rdt@gmail.com'
#     subject text
#     html_part do
#       body "asdf"
#     end
#   end
# end

def notify_of_review(reviewee)
  Mail.deliver do
    to reviewee
    from 'IRDP <irdp.rdt@gmail.com>'
    subject "You've been reviewed!"
    html_part do
      body "Hey there!<br><br>Someone has written a review about you and it's been approved (or recently edited) by an IRDP RDT member. Head over to your <a href=\"http://refdevelopment.com/profile\">profile</a> to read it!<br><br>~the IRDP<br><br>"
    end
  end
end

# def report_bad(user_id)
#   Mail.deliver do
#     to 'irdp.rdt@gmail.com'
#     from 'IRDP <irdp.rdt@gmail.com>'
#     subject 'Someone submitted a test early!'
#     html_part do
#       body "User #{user_id} just tried to finish a test before the alotted amount of time. Check it out!"
#     end
#   end
# end

# def report_paypal
#   Mail.deliver do
#     to 'irdp.rdt@gmail.com'
#     from 'IRDP <irdp.rdt@gmail.com>'
#     subject 'paypal failure?'
#     html_part do
#       body "User just maybe didn't get recognized for their hr payment!"
#     end
#   end
# end

def weekly_testing_update
  # some nice email styling
  td_start = '<td style="background-color: white; padding: 3px;">'
  table_start = '<table style="width: 800px; background-color: darkgray;">'

  body_text = "These are all of the people who have attempted an IRDP test in the past week. An 80% is required to pass.
    <br><br>
    #{table_start}
      <tr>
      #{td_start}<strong>Name</strong></td>
      #{td_start}<strong>Type</strong></td>
      #{td_start}<strong>Percentage</strong></td>
      #{td_start}<strong>Time (UTC)</strong></td>
      </tr>"
  begin
    user_dump = settings.client.query("_User").eq('region','QUK').get
    users = {}
    user_dump.each do |u|
      users[u['objectId']] = name_maker(u)
    end

    test_dump = settings.client.query("testAttempt").tap do |q|
      q.limit = 1000
      q.greater_than("updatedAt", Parse::Date.new((Time.now - 604800).to_datetime))
    end.get

    test_dump.each do |t|
      if users.include?(t['taker'])
        body_text += "<tr>#{td_start}#{users[t['taker']]}</td>
          #{td_start}#{settings.test_names[t['type'].to_sym]}</td>
          #{td_start}#{t['percentage']}%</td>
          #{td_start}#{Time.parse(t['updatedAt']).strftime(settings.time_string)}</td>
          </tr>"
      end
    end

    body_text += "</table><br><br>If you've got any questions, reach out to David at irdp.rdt@gmail.com.<br><br> ~IRDP"

    Mail.deliver do
      # to 'irdp.rdt@gmail.com'
      to 'gameplay@quidditchuk.org'
      from 'IRDP <irdp.rdt@gmail.com>'
      subject 'Weekly Test Result Update'
      html_part do
        content_type 'text/html; charset=UTF-8'
        body body_text
      end
    end

    # this is for zapier
    return 1
  rescue
    return nil
  end
end

# Rendering helpers
def email_link(a={})
  if a.include?(:subject)
    @subject = URI.encode("?subject=#{a[:subject]}")
  else
    @subject = ''
  end

  if a.include?(:text)
    @display_text = a[:text]
  else
    @display_text = 'irdp.rdt@gmail.com'
  end
  haml :email_link
end

def local_time(time, message='', text=nil)
  @time = time
  @message = message
  @display_text = text || 'UTC'
  haml :local_time
end

def paypal_button
  @id = session[:user]['objectId']
  haml :_paypal
end

not_found do
  display({path: "404", layout: :f, old: :f})
end

error 500 do
  display({path: "500", layout: :f, old: :f})
end

# kill switch
def before
end
before do
  # pp session
  if settings.development?
    # this is the local switch
    @killed = false
  else
    # this is the production (live) switch
    @killed = settings.killed
  end

  # so we never have a null language
  if logged_in?
    @lang = session[:user]['lang'] || 'EN'

    # check for updated region
    if session[:user]['region'] == 'MQN'
      session[:user] = pull_user.to_h
    end
  else
    @lang = "EN"
  end

  # admins can use site even when it's locked
  if !admin?
    if @killed && !['/layout','/login','/logout','/release','/paid','/styles.css', '/off'].include?(request.path_info)
      redirect '/off'
    end
  end

  # subdomain redirection
  if !settings.development?
    url = Domainatrix.parse(request.url)
    if url.subdomain.size > 0
      redirect 'http://refdevelopment.com'+url.path
    end
  end

  @layout = settings.layout_hash[@lang]


  # pp request if settings.development?

end

# routes
def index
end
get '/' do
  @section = "index"
  display({path: :index, old: :f})
end

def about
end
get '/about' do
  @section = "info"
  display({old: :f})
end

get '/break' do
  halt 500
end

# it would be nice to be able to download all of this info as a CSV
def admin
end
get '/admin' do
  @title = "Admin"
  if !logged_in?
    redirect '/login?d=/admin'
  elsif !admin?
    flash[:issue] = @layout['issues']['admin']
    redirect '/'
  else
    @review_list = []
    reviews = settings.client.query("review").tap do |r|
      r.limit = 1000
    end.get

    ref_dump = settings.client.query("_User").tap do |r|
      r.limit = 1000
    end.get

    refs = {}
    # turn refs inside out
    ref_dump.each do |r|
      refs[r['objectId']] = r
    end

    reviews.each do |r|
      if r['comments'].size > 0
        if r['referee'] && refs.include?(r['referee'].parse_object_id)
          ref = refs[r['referee'].parse_object_id]
          rid = ref['objectId']
          r['refName'] = name_maker(ref)
          r['rid'] = rid

          # hide the name of reviews made about you
          if r['referee'].parse_object_id == session[:user]['objectId']
            r['reviewerName'] = "REDACTED"
            r['reviewerEmail'] = "REDACTED"
          end
        end

        r['created'] = Time.parse(r['createdAt']).strftime("%m/%d/%Y")

        @review_list << r
      end
    end

    display
  end
end

def api
end
get '/api/refs/:refs' do
  ref_ids = params[:refs].split ','
  settings.client.query("_User").tap do |q|
    q.value_in("objectId",ref_ids)
    q.keys = "email,firstName,lastName,team,assRef,snitchRef,headRef,passedFieldTest,region,profPic"
  end.get.to_json
end

def cm
end
get '/cm' do
  # cases:
  #   A: no attempts at all
  #   B: no attempts for this test
  #   C: attempted this test

  if !params.include?('cm_user_id')
    flash[:issue] = @layout['issues']['cm']
    redirect '/'
  end

  attempt_list = settings.client.query("testAttempt").eq("taker", params[:cm_user_id]).get
  if attempt_list.empty?
    # A
    att = settings.client.object("testAttempt")
    att["taker"] = params[:cm_user_id]
  else
    att = attempt_list.select do |a|
      a["type"] == params[:cm_return_test_type]
    end.first
    if att.nil?
      # B
      att = settings.client.object("testAttempt")
      att["taker"] = params[:cm_user_id]
    else
      # C
      if Time.now.utc - Time.parse(att['time']) < settings.waiting - 500
        flash[:issue] = @layout['issues']['quick']
        # report_bad(att['taker'])
        redirect '/'
      end
    end
  end

  att["score"] = params[:cm_ts].to_i
  att["percentage"] = params[:cm_tp].to_i
  att["duration"] = params[:cm_td]
  att["type"] = params[:cm_return_test_type]
  att["time"] = Time.now.utc.to_s
  att.save

  user_to_update = pull_user(params[:cm_user_id])

  email = user_to_update['email']
  if params[:cm_tp].to_i >= 80
    pass = true
    t_flash = @layout['issues']['pass']
    t_flash += settings.test_names[params[:cm_return_test_type].to_sym]
    t_flash += @layout['ref_test']
    t_flash += @layout['issues']['go_you']
    flash[:issue] = t_flash
    user_to_update[params[:cm_return_test_type].to_s+"Ref"] = true
  else
    pass = false
    flash[:issue] = @layout['issues']['fail']
  end

  user_to_update['hrWrittenAttemptsRemaining'] -= 1 if att['type'] == 'head'

  user_to_update.save

  email_results(email, pass, params[:cm_return_test_type]) if !settings.development?
  redirect '/pull' if pass
  redirect "/testing/#{params[:cm_return_test_type]}"
end

def contact
end
get '/contact' do
  @section = "info"

  display({old: :f})
end

def create
end
get '/create' do
  @team_list = Set.new
  teams = settings.client.query("_User").tap do |u|
    u.exists("team")
    u.limit = 1000
  end.get
  teams.each do |t|
    @team_list << t["team"]
  end
  @team_list = @team_list.to_a
  @region_keys = settings.region_names
  display(old: :f)
end

post '/create' do
  puts "SIGNING UP WITH KEY #{params[:registration]} FOR REGION #{params[:region]}" if params[:registration] && params[:registration].size > 0

  user = settings.client.user({
    # username is actually email, secretly
    :username => params[:username].downcase,
    :password => params[:password].rstrip,
    :email => params[:username].downcase,
    :assRef => false,
    :snitchRef => false,
    :headRef => false,
    :hrWrittenAttemptsRemaining => 0,
    :passedFieldTest => false,
    :admin => false,
    :paid => validate(params[:registration],settings.region_hash[params[:region]]),
    :lang => params[:lang] || 'EN',
    :firstName => params[:fn],
    :lastName => params[:ln],
    :team => params[:team],
    # because of dropdown, there shouldn't ever be no region, but this is
    # just in case. Region errors really break stuff.
    :region => settings.region_hash[params[:region]] || "NONE"
  })


  begin
    session[:user] = user.save.to_h
    t_flash = @layout['issues']['created']
    # pp "flash is #{@layout}"
    t_flash += session[:user]['paid'] ? '' : 'non'
    t_flash += @layout['issues']['version']

    flash[:issue] = t_flash
    redirect '/'
  rescue
    # usually only fails for invalid email, but it could be other stuff
    # may way to rescue specific parse errors
    flash[:issue] = @layout['issues']['invalid']
    redirect back
  end
end

def currency
end
get '/currency' do
  # @c is the index for the currency as seen in app.js
  reg = session[:user]['region']
  if ['AUST'].include?(reg)
    i = 0
  elsif ['CANA'].include?(reg)
    i = 1
  # elsif ['ITAL', 'NORW', 'BQF', 'MQN', 'PLQ', 'OTHR'].include?(reg)
  #   i = 2
  elsif ['QUK'].include?(reg)
    i = 3
  elsif ['USQ'].include?(reg)
    i = 4
  else # EUR
    i = 2
  end
  {i: i}.to_json
end

def donate
end
get '/donate' do
  display({old: :f})
end

# def faq
# end
# get '/faq' do
#   @section = "info"
#   display({old: :f})
# end

def field
end
get '/field/:referee' do
  if !admin?
    redirect back
  end
  ref = settings.client.query("_User").eq("objectId", params[:referee]).get.first
  puts ref
  ref['passedFieldTest'] = true
  ref.save
  flash[:issue] = "#{name_maker(ref)} has passed their field test!"
  redirect "/search/#{params[:reg]}"
end

get '/field_test' do
  if !logged_in?
    flash[:issue] = @layout['issues']['test_login']
    redirect "/login?d=/field_test"
  elsif !session[:user]['headRef']
    flash[:issue] = @layout['issues']['hr_first']
    redirect '/testing/head'
  elsif session[:user]['passedFieldTest']
    flash[:issue] = @layout['issues']['field_test_passed']
    redirect back
  end

  display({old: :f})
end

post '/field_test' do
  test = settings.client.object("fieldTestSignup")
  test["region"] = session[:user]["region"]
  test["name"] = name_maker(session[:user])
  test["email"] = session[:user]["email"]
  test["taker"] = session[:user]["objectId"]

  test["tournament"] = params[:tournament]
  test["tournamentDate"] = params[:date]
  test["link"] = params[:link]

  test.save

  flash[:issue] = @layout["issues"]["test_signup"]
  redirect '/profile'
end

get '/field_tests' do
  @title = "Field Test Signups"
  if !logged_in?
    redirect '/login?d=/admin'
  elsif !admin?
    flash[:issue] = @layout['issues']['admin']
    redirect '/'
  else
    @tests = settings.client.query("fieldTestSignup").tap do |r|
      r.limit = 1000
    end.get
  end
  display({old: :t})
end

def info
end
get '/info' do
  @section = 'info'
  display({old: :f})
end

def lock
end
get '/lock' do
  if params[:code] != ENV['REFBOOK_LOCK_CODE']
    flash[:issue] = 'Invalid Code'
    redirect '/'
  else
    settings.killed = true
  end
  "Successfuly locked at #{Time.now} - #{settings.killed}"
end

def login
end
get '/login' do
  @title = "Login"
  display({old: :f})
end

post '/login' do
  begin
    session[:user] = Parse::User.authenticate(params[:username].downcase, params[:password].rstrip, settings.client).to_h
    session.options[:expire_after] = 2592000 # 30 days
    redirect params[:d]
  rescue
    flash[:issue] = @layout['issues']['credentials']
    redirect "/login?d=#{params[:d]}"
  end
end

def logout
end
get '/logout' do
  session[:user] = nil
  flash[:issue] = @layout['issues']['logout']
  redirect '/'
end

def off
end
get '/off' do
  if !@killed
    # flash[:issue] = "Maintenance is done, carry on!"
    redirect '/'
  else
    display({path: :off, layout: :f, old: :f})
  end
end

def pay
end
get '/pay' do
  @title = 'Purchase an IRDP Membership!'
  if logged_in?
    @id = session[:user]['objectId']
  end
  display({old: :f})
end

def paid
end
# get ca$h get m0ney
post '/paid' do
  begin
    id = params["custom"].split('|')[0].split('=')[1]
    type = params["custom"].split('|')[1].split('=')[1]
  rescue
    # puts "IPN FAILURE"
    # pp params
    # report_paypal
    # status 500
    # return {status: 500, message: "not ok"}.to_json
    return 200
  end
  # unnamed ref payments don't count
  if id == 'Sb33WyBziN'
    return {status: 200, message: "ok"}.to_json
  end
  user_to_update = pull_user(id)
  # puts params
  begin
    if type == 'hr'
      user_to_update['hrWrittenAttemptsRemaining'] = 4
    elsif type == 'ac'
      user_to_update['paid'] = true
    else
      halt 400
    end
    user_to_update.save
    # pp "payment registered for #{user_to_update['firstName']} #{user_to_update['lastName']}"
    # register_purchase("#irdp #{user_to_update['firstName']} #{user_to_update['lastName']} ||| #{type} ||| #{user_to_update['objectId']} ||| #{user_to_update['region']}")
    return {status: 200, message: "ok"}.to_json
  rescue Exception => e
    puts e.message
    puts e.backtrace.inspect
    status 500
    return {status: 500, message: "not ok"}.to_json
  end
end

def profile
end
get '/profile' do
  if !logged_in?
    redirect '/login?d=/profile'
  end
  @review_list = []

  reviews = settings.client.query("review").tap do |q|
    q.eq("referee", Parse::Pointer.new({
      "className" => "_User",
      "objectId"  => session[:user]['objectId']
    }))
  end.get

  @field_tests = settings.client.query("fieldTestSignup").tap do |q|
    q.eq("taker",session[:user]["objectId"])
  end.get

  # count reviews
  @total = 0
  @counts = {'excellent'=> 0, 'good' => 0, 'average' => 0, 'poor' => 0}
  reviews.each do |r|
    if r['comments'].size == 0
      @counts[r['rating']] += 1
    elsif r['show']
      r['rating'].capitalize!
      r['type'] = settings.test_names[r['type'].to_sym]
      @review_list << r
      @total += 1
    end
  end

  @url = session[:user]['profPic'] ? session[:user]['profPic'] : '/images/person_blank.png'
  display({old: :f})
end

get '/profile/:ref_id' do
  @ref = settings.client.query('_User').eq("objectId",params[:ref_id]).get.first
  if @ref.nil?
    flash[:issue] = @layout['issues']['not_found']
    redirect '/search/ALL'
  else
    if logged_in?
      # @star = settings.stars.find_one({to: params[:ref_id], from: session[:user]['objectId']})
    else
      # @star = nil
    end
    @title = "#{@ref['firstName']} #{@ref['lastName']}"
    @url = @ref['profPic'] ? @ref['profPic'] : '/images/person_blank.png'

    display({path: :public_profile, old: :f})
  end
end

def pull
end
get '/pull' do
  if !logged_in?
    flash[:issue] = @layout['issues']['refresh']
    redirect '/login?d=/pull'
  else
    session[:user] = pull_user.to_h
    flash[:issue] = @layout['issues']['pull']
    redirect back
  end
end

def qr
end
get '/qr' do
  @title = "QR"
  if !logged_in?
    redirect '/login?d=/qr'
  end
  u = "http://refdevelopment.com/review/#{session[:user]['objectId']}"
  @review_qr = "https://chart.googleapis.com/chart?cht=qr&chs=300x300&chl=#{URI::encode(u)}"
  display
end

def refresh
end
get '/refresh' do
  # just to make sure we beat the paypal ping
  sleep(3.5)
  session[:user] = pull_user.to_h
  flash[:issue] = @layout['issues']['confirm']
  redirect '/'
end

def reset
end
get '/reset' do
  @title = "Reset Your Password"
  display
end

post '/reset' do
  # begin
    Parse::User.reset_password(params[:email], settings.client)
    flash[:issue] = @layout['issues']['reset']
    redirect '/logout'
  # rescue
  #   flash[:issue] = @layout['issues']['reset_fail']
  #   redirect back
  # end
end

def release
end
get '/release' do
  # this isn't display because all the languages are already there
  # it could be updated if we add a language we didn't press release in
  haml :release, layout: false
end

def report
end
# this is a get cause it gets hit by Zapier right now, maybe change to ironworks soon?
get '/report' do
  good = weekly_testing_update
  if good
    {status: 200}.to_json
  else
    {status: 500}.to_json
  end
end

def review
end
get '/review' do
  @title = "Review a Referee"
  @section = 'review'

  @region_keys = settings.region_names
  @region_codes = settings.region_codes
  q = settings.client.query("_User").tap do |u|
    u.limit = 1000
  end.get
  @refs = {}

  @region_codes.each do |r|
    @refs[r] = []
  end


  q.each do |person|
    # you can only review if they've got some sort of cert
    if person["assRef"] or person["snitchRef"]
      # [id, fN + lN]
      p = [person['objectId'], name_maker(person)]

      @refs[person['region']] << p
    end
  end

  @refs = @refs.to_json
  display({old: :f})
end

post '/review' do
  # process recapcha
  verify_url = "https://www.google.com/recaptcha/api/siteverify?secret=#{ENV['REFBOOK_RECAPTCHA_SECRET']}&response=#{params[:'g-recaptcha-response']}"
  resp = HTTParty.get(verify_url)

  # down with robots!
  if !resp['success']
    flash[:issue] = 'Invalid ReCaptcha, try again'
    redirect back
  end

  # save the review
  rev = settings.client.object('review')
  rev['reviewerName'] = params[:name]
  rev['reviewerEmail'] = params[:email]
  rev['isCaptain'] = params[:captain] ? true : false
  rev['region'] = params[:region] || "None"

  point = Parse::Pointer.new({})
  point.class_name = "_User"
  # the correct user_id or hardcoded Unnamed Ref
  point.parse_object_id = params[:referee] || "Sb33WyBziN"

  rev['referee'] = point
  rev['type'] = params[:type]

  rev['date'] = params[:date]
  rev['team'] = params[:team]
  rev['opponent'] = params[:opponent]
  rev['rating'] = params[:rating]
  rev['comments'] = params[:comments]
  # show should be false by default, true for testing
  rev['show'] = false
  rev.save

  flash[:issue] = @layout['issues']['review']
  redirect back
end

get '/review/:id' do
  @ref = settings.client.query("_User").eq("objectId", params[:id]).get.first
  halt 404 if @ref.nil?

  @url = @ref['profPic'] ?
      @ref['profPic'] : '/images/person_blank.png'

  @title = "Review #{@ref['firstName']} #{@ref['lastName']}"
  @region_keys = settings.region_names
  # this is included so there's no error because of a missinv variable
  @refs = {}
  display({path: :review ,old: :f})
end

get '/reviews/:review_id' do
  @title = "Edit a Review"
  if !admin?
    # still using old bounce because there's no way someone is linking
    # right to this page. hopefully.
    flash[:issue] = @layout['issues']['admin']
    redirect '/'
  else
    @r = settings.client.query("review").eq("objectId", params[:review_id]).tap do |r|
      r.include = "referee"
    end.get.first
    @name = name_maker(@r['referee'])
    @r['reviewerName'] = 'REDACTED' if @r['referee'].parse_object_id == session[:user]['objectId']
    @review = @r.to_json
    display({path: :edit_review, old: :t})
  end
end

post '/reviews/:review_id' do
  r = settings.client.query("review").eq("objectId", params[:review_id]).get.first
  reviewee = settings.client.query("_User").eq("objectId",r['referee'].parse_object_id).get.first['email']
  r['show'] = to_bool(params[:show])
  puts "show: ",r['show']
  r['comments'] = params[:comments]

  notify_of_review(reviewee) if r['show']

  r.save

  flash[:issue] = "Review saved, it will #{r['show'] ? "" : "not"} be shown"
  redirect '/admin'
end

def revoke
end
get '/revoke/:uid' do
  redirect back unless admin?

  user_to_update = pull_user(params[:uid])
  user_to_update["#{params[:which]}Ref"] = false
  user_to_update.save

  flash[:issue] = "#{settings.test_names[params[:which].to_sym]} ref certification revoked!"

  redirect back
end

def risk
end
get '/risk' do
  @title = "IRDP Territories"
  display({old: :t})
end


def search
end
get '/search/:region' do
  @title = "Directory by Region"
  @section = 'search'

  @reg = params[:region].upcase
  @region_title = reg_reverse(@reg)

  @region_values = settings.region_codes.reject{|p| p[0..1] == "US"}
  @region_keys = []
  @region_values.each{|r| @region_keys << reg_reverse(r)}

  if @region_title.nil?
    halt 404
  end

  # stars_dump = settings.stars.find.to_a

  # @stars = {}

  # @mine = Set.new

  # stars_dump.each do |s|
  #   if @stars.include?(s['to'])
  #     @stars[s['to']] += 1
  #   else
  #     @stars[s['to']] = 1
  #   end

  #   if logged_in? && s['from'] == session[:user]['objectId']
  #     @mine << s['to']
  #   end
  # end

  # this currently works only with my version of the gem until the PR is merged
  fields = "firstName,lastName,team,assRef,snitchRef,headRef,passedFieldTest,region"

  q = settings.client.query("_User").tap do |r|
    r.limit = 1000
    r.keys = fields
  end
  q.eq("region", @reg) if @reg != 'ALL'

  q = q.get

  @refs = []
  # build each row of the table
  q.each do |person|
    if person["assRef"] || person["snitchRef"] || params[:show] == "all"
      @refs << person
    end
  end

  @total = @refs.size

  display({path: :search, old: :f})
end

def settings
end
get '/settings' do
  if !logged_in?
    redirect '/login?d=/settings'
  end
  @title = "Settings"
  display({old: :f})
end

post '/settings' do
  begin
    if params.include?('tests') && settings.development?

      if params.include?('ar')
        session[:user]['assRef'] = true
      else
        session[:user]['assRef'] = false
      end

      if params.include?('sr')
        session[:user]['snitchRef'] = true
      else
        session[:user]['snitchRef'] = false
      end

      if params.include?('hr')
        session[:user]['headRef'] = true
      else
        session[:user]['headRef'] = false
      end

      if params.include?('ft')
        session[:user]['passedFieldTest'] = true
      else
        session[:user]['passedFieldTest'] = false
      end

    else
      session[:user]['email'] = params[:username] unless params[:username].nil?
      session[:user]['username'] = params[:username] unless params[:username].nil?
      session[:user]['lang'] = params[:lang] unless params[:lang].nil?
      session[:user]['team'] = params[:team] unless params[:team].nil?
    end

    refresh_session!
    flash[:issue] = @layout['issues']['settings']
    redirect '/'

  rescue
    session[:user] = pull_user.to_h
    flash[:issue] = @layout['issues']['invalid']
    redirect '/settings'
  end
end

def star
end
get '/star/:id' do
  if !logged_in?
    redirect "/login?d=/star/#{params[:id]}"
  end

  if !session[:user]['headRef']
    # probably a better thing to do
    flash[:issue] = "You heed to be an HR before you can star people"
    redirect '/'
  end

  star = {to: params[:id], from: session[:user]['objectId']}

  if params[:pop] == "1"
    begin
      # settings.stars.remove(star)
      flash[:issue] = "Successfully unstarred"
      redirect "/profile/#{params[:id]}"
    # rescue
    end
  else
    begin
      # settings.stars.save(star)
      flash[:issue] = "Successfully starred"
      redirect "/profile/#{params[:id]}"
    rescue
      {status: 403, message: "You've already starred them"}.to_json
    end
  end

end

def testing
end
get '/testing/?' do
  @title = "Testing Information Center"
  @section = 'testing'
  display({old: :f})
end

get '/testing/:which' do
  #   find all test attempts from that user id, find the (single) type attempt,
  #   then, update it with most recent attempt (and Time.now) for comparison.
  #   If they pass, display the link for the relevant test(s). When they finish,
  #   update the relevent test entry wtih the most recent test

  # if params[:which].nil?
  #   redirect '/testing'
  # end

  if !logged_in?
    flash[:issue] = @layout['issues']['test_login']
    redirect "/login?d=/testing/#{params[:which]}"
  end

  @title = "#{settings.test_names[params[:which].to_sym]} Referee Test"
  @section = 'testing'
  # right now, which can be anything. Nbd?

  unless["head", "snitch", "ass", "sample"].include?(params[:which])
    halt 404
  end

  # why do computation if they've alreayd passed?
  display({path: :test_links, old: :f}) if session[:user][params[:which]+"Ref"]

  @good = true
  @attempts_remaining = session[:user]['hrWrittenAttemptsRemaining'].to_i > 0
  @prereqs_passed = true

  @tests = {
    ass: 'kcp57ec4ee09e4ba',
    snitch: '4ng57ec4c84268e0',
    head: 'kxc57ec51f7cfdec',
    sample: "xnj533d065451038"
  }
  # if session[:user]['region'] == "CANA"
  #   @tests[:snitch] = CANADIAN TEST # test w/ off pitch
  # end
  @rb = 'IQARB16-18'

  # refresh user object
  session[:user] = pull_user.to_h

  if params[:which] == 'head'
    if !session[:user]['assRef'] || !session[:user]['snitchRef']
      @prereqs_passed = false
    end
  end
  attempt_list = settings.client.query("testAttempt").eq("taker", session[:user]['objectId']).get
  if !attempt_list.empty?
    # at least 1 attempt
    att = attempt_list.select do |a|
      # hardcoded - will do actual test discrim later
      a['type'] == params[:which]
    end
    if !att.empty?
      # they've taken this test sometime
      att = att.first

      if Time.now.utc - Time.parse(att['time']) < settings.waiting
        @good = false
        @try_unlocked = Time.parse(att['time']) + settings.waiting
        @t1 = Time.now.utc
        @t2 = Time.parse(att['time'])
      end
    end
  end

  display({path: :test_links, old: :f})
end

def upload
end
post '/upload' do
  photo = settings.client.file({
    body: IO.read(params[:myfile][:tempfile]),
    local_filename: URI.encode(params[:myfile][:filename]),
    content_type: params[:myfile][:type]
  })

  begin
    h = photo.save
    puts h
    session[:user]['profPic'] = photo.url
    refresh_session!
    redirect '/profile'
  rescue Parse::ParseProtocolError
    puts "INVALID FILENAME #{params[:myfile][:filename]}"
    flash[:issue] = 'Filename has invalid characters. Can only use letters, numbers, underscores'
    redirect back
  end
end

def valid
end
get '/validate' do
  puts "TRYING TO VALIDATE #{session[:user]['objectId']} WITH CODE #{params[:code]}"
  if validate(params[:code],session[:user]['region'])
    user_to_update = pull_user
    user_to_update['paid'] = true
    session[:user] = user_to_update.save.to_h
    flash[:issue] = @layout['issues']['validate']
    puts "DID VALIDATE"
    redirect '/'
  else
    puts "DID NOT VALIDATE"
    flash[:issue] = @layout['issues']['validont']
    redirect '/settings'
  end
end

get '/impersonate' do
  if settings.development?
    session[:user] = pull_user(params[:id]).to_h
  end

  redirect '/'
end

# renders css
get '/styles.css' do
  scss :refbook
end

