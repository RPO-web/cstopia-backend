defmodule CstopiaBackend.Repo.Migrations.FixAvatarUrls do
  use Ecto.Migration
  import Ecto.Query

  def up do
    # Create a function to extract the avatar hash from a full URL
    execute """
    CREATE OR REPLACE FUNCTION extract_avatar_hash(url text) RETURNS text AS $$
    DECLARE
      filename text;
      hash text;
    BEGIN
      IF url IS NULL THEN
        RETURN NULL;
      END IF;

      -- Check if the URL contains 'cdn.discordapp.com/avatars'
      IF url LIKE '%cdn.discordapp.com/avatars/%' THEN
        -- Extract the filename (last part after the slash)
        filename := substring(url from '[^/]+$');
        -- Extract the hash (part before the dot)
        hash := split_part(filename, '.', 1);
        RETURN hash;
      ELSE
        -- If it's already just a hash, return it as is
        RETURN url;
      END IF;
    END;
    $$ LANGUAGE plpgsql;
    """

    # Update all users with avatar URLs to just use the hash
    execute """
    UPDATE users
    SET avatar = extract_avatar_hash(avatar)
    WHERE avatar LIKE 'http%';
    """

    # Drop the function after we're done
    execute "DROP FUNCTION extract_avatar_hash;"
  end

  def down do
    # This migration cannot be undone once avatar hashes are extracted
    # We would need the original URLs to revert
  end
end
