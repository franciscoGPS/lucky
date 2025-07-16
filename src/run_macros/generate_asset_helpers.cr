require "json"
require "colorize"

private class AssetManifestBuilder
  property retries
  @retries : Int32 = 0
  @manifest_path : String
  @build_system : String = "vite"
  @max_retries : Int32
  @retry_after : Float64

  def initialize(@manifest_path : String = "./public/mix-manifest.json", @build_system : String = "vite")
    @manifest_path = File.expand_path(@manifest_path)

    # These values can be configured at compile time via environment variables:
    # - LUCKY_ASSET_MANIFEST_RETRY_COUNT: Number of times to retry (default: 20)
    # - LUCKY_ASSET_MANIFEST_RETRY_DELAY: Delay between retries in seconds (default: 0.25)
    @max_retries = ENV["LUCKY_ASSET_MANIFEST_RETRY_COUNT"]?.try(&.to_i) || 20
    @retry_after = ENV["LUCKY_ASSET_MANIFEST_RETRY_DELAY"]?.try(&.to_f) || 0.25
  end

  def build_with_retry
    if manifest_exists?
      case @build_system
      when "vite"
        build_with_vite_manifest
      when "bun"
        build_with_bun_manifest
      else
        build_with_mix_manifest
      end
    else
      retry_or_raise_error
    end
  end

  private def retry_or_raise_error
    if retries < @max_retries
      self.retries += 1
      sleep(@retry_after)
      build_with_retry
    else
      raise_missing_manifest_error
    end
  end

  private def build_with_mix_manifest
    manifest_file = File.read(@manifest_path)
    manifest = JSON.parse(manifest_file)

    manifest.as_h.each do |key, value|
      # "/js/app.js" => "js/app.js",
      key = key.gsub(/^\//, "").gsub(/^assets\//, "")
      puts %({% ::Lucky::AssetHelpers::ASSET_MANIFEST["#{key}"] = "#{value.as_s}" %})
    end
  end

  private def build_with_vite_manifest
    manifest_file = File.read(@manifest_path)
    manifest = JSON.parse(manifest_file)

    # Check if this is a dev manifest (has "url" and "inputs" properties)
    if manifest.as_h.has_key?("url") && manifest.as_h.has_key?("inputs")
      # This is a dev manifest from vite-plugin-dev-manifest
      base_url = manifest["url"].as_s
      inputs = manifest["inputs"].as_h

      inputs.each do |_, value|
        path = value.as_s
        # Remove src/ prefix to match Lucky's convention
        clean_key = path.starts_with?("src/") ? path[4..] : path
        puts %({% ::Lucky::AssetHelpers::ASSET_MANIFEST["#{clean_key}"] = "#{base_url}#{path}" %})
      end
    else
      # This is a production manifest
      manifest.as_h.each do |key, value|
        # Skip chunks that start with underscore (these are shared chunks)
        next if key.starts_with?("_")

        # Only process entries that have a src property
        if value.as_h.has_key?("src")
          # Remove the "src/" prefix from the key to match Lucky's convention
          clean_key = key.starts_with?("src/") ? key[4..] : key
          puts %({% ::Lucky::AssetHelpers::ASSET_MANIFEST["#{clean_key}"] = "/#{value["file"].as_s}" %})
        end
      end
    end
  end

  private def build_with_bun_manifest
    manifest_file = File.read(@manifest_path)
    manifest = JSON.parse(manifest_file)

    # Bun's manifest format can vary, but typically follows a structure similar to:
    # {
    #   "inputs": {
    #     "src/app.ts": {
    #       "output": "app-[hash].js",
    #       "imports": []
    #     }
    #   },
    #   "outputs": {
    #     "app-[hash].js": {
    #       "input": "src/app.ts"
    #     }
    #   }
    # }

    if manifest.as_h.has_key?("inputs")
      # Handle Bun's inputs format
      inputs = manifest["inputs"].as_h
      inputs.each do |key, value|
        # Remove "src/" prefix to match Lucky's convention
        clean_key = key.starts_with?("src/") ? key[4..] : key

        if value.as_h.has_key?("output")
          output_path = value["output"].as_s
          puts %({% ::Lucky::AssetHelpers::ASSET_MANIFEST["#{clean_key}"] = "/#{output_path}" %})
        end
      end
    elsif manifest.as_h.has_key?("outputs")
      # Handle Bun's outputs format
      outputs = manifest["outputs"].as_h
      outputs.each do |output_file, value|
        if value.as_h.has_key?("input")
          input_path = value["input"].as_s
          # Remove "src/" prefix to match Lucky's convention
          clean_key = input_path.starts_with?("src/") ? input_path[4..] : input_path
          puts %({% ::Lucky::AssetHelpers::ASSET_MANIFEST["#{clean_key}"] = "/#{output_file}" %})
        end
      end
    else
      # Fallback: treat as simple key-value mapping like mix-manifest
      manifest.as_h.each do |key, value|
        # "/js/app.js" => "js/app.js",
        key = key.gsub(/^\//, "").gsub(/^assets\//, "")
        puts %({% ::Lucky::AssetHelpers::ASSET_MANIFEST["#{key}"] = "#{value.as_s}" %})
      end
    end
  end

  private def manifest_exists?
    File.exists?(@manifest_path)
  end

  private def raise_missing_manifest_error
    puts "Manifest at #{@manifest_path} does not exist".colorize(:red)
    puts "Make sure you have compiled your assets".colorize(:red)
  end
end

begin
  manifest_path = ARGV[0]
  build_system = ARGV[1]? == "vite"

  builder = if manifest_path.blank?
              AssetManifestBuilder.new
            else
              AssetManifestBuilder.new(manifest_path, build_system)
            end

  builder.build_with_retry
rescue ex
  puts ex.message.colorize(:red)
  raise ex
end
