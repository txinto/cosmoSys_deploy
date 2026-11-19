# frozen_string_literal: true

require 'net/http'
require 'nokogiri'
variant = ARGV.shift
abort('Unknown deployment variant') unless %w[base requirements].include?(variant)
active = ARGV.uniq
catalog = File.readlines('/opt/cosmosys-deploy/plugins.conf', chomp: true).filter_map do |line|
  line.split('=', 2) if line.match?(/\A[A-Z_a-z0-9]+=/)
end.to_h
directory = ->(id) { catalog["PLUGIN_#{id}_DIRECTORY"].presence || id }
expected = ['cosmosys'] + (variant == 'requirements' ? ['cosmosys_req'] : []) + active
expected.select! { |id| File.read(Rails.root.join('plugins', directory.call(id), 'init.rb')).include?('Plugin.register') }
actual = Redmine::Plugin.registered_plugins.keys.map(&:to_s)
abort("Registered plugins #{actual.sort.inspect}, expected #{expected.sort.inspect}") unless actual.sort == expected.sort
all = catalog.fetch('COSMOSYS_OPTIONS').split.flat_map { |option| catalog.fetch("OPTION_#{option}_PLUGINS").split }.uniq
dormant = all - active
abort('Dormant plugin is installed') if dormant.any? { |id| Rails.root.join('plugins', directory.call(id)).exist? }
loaded = $LOADED_FEATURES.join("\n")
Bundler.definition.dependencies.each do |dependency|
  owners = dormant.select { |id| dependency.groups.include?("cosmosys_#{id}".to_sym) }
  next if owners.empty? || dependency.groups.include?(:default)
  abort("Dormant gem #{dependency.name} is loaded") if loaded.include?("/gems/#{dependency.name}-")
end
active.each do |id|
  assets = Rails.root.join('plugins', directory.call(id), 'assets')
  next unless assets.directory?
  file = Dir.glob(assets.join('*', '**', '*')).sort.find { |path| File.file?(path) && !File.basename(path).start_with?('.') }
  next unless file
  # Redmine's asset pipeline removes the type directory (javascripts,
  # stylesheets, images), preserving directories below it.
  relative = Pathname.new(file).relative_path_from(assets).each_filename.to_a.drop(1).join('/')
  logical = "plugin_assets/#{id}/#{relative}"
  path = ActionController::Base.helpers.asset_path(logical)
  response = Net::HTTP.get_response(URI("http://127.0.0.1:3000#{path}"))
  abort("#{id} asset #{path} answered #{response.code}") unless response.is_a?(Net::HTTPSuccess)
end
unless ApplicationController.helpers.current_theme&.favicon?
  login = Net::HTTP.get_response(URI('http://127.0.0.1:3000/login'))
  abort("Login page answered #{login.code}") unless login.is_a?(Net::HTTPSuccess)
  icons = Nokogiri::HTML(login.body).css('head link').select { |link| link['rel'].to_s.split.include?('icon') }
  icon = icons.first
  unless icons.size == 1 && icon['type'] == 'image/svg+xml' && icon['href'].to_s.match?(%r{\A/assets/plugin_assets/cosmosys/favicon-[0-9a-f]+\.svg\z})
    abort('The default cosmoSys favicon is missing or duplicated')
  end
  favicon = Net::HTTP.get_response(URI("http://127.0.0.1:3000#{icon['href']}"))
  unless favicon.is_a?(Net::HTTPSuccess) && Nokogiri::XML(favicon.body).root&.name == 'svg'
    abort('The cosmoSys favicon asset is not served as SVG')
  end
end
puts 'Registered/dormant plugins, gem groups and assets: PASS'
