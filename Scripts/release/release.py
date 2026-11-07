# /// script
# requires-python = ">=3.11"
# dependencies = ["click>=8.1", "cryptography>=45", "dmgbuild==1.6.7"]
# ///
"""Builds, signs, notarizes, and packages Roga, one step per command.

The release workflow (.github/workflows/release.yml) runs these commands in
order, and so can anyone with the credentials on their own Mac:

    uv run Scripts/release/release.py archive --version 0.1.0 --build 212 --out build/release
    uv run Scripts/release/release.py notarize build/release/Roga.app
    uv run Scripts/release/release.py zip build/release/Roga.app dist/Roga-0.1.0.zip
    uv run Scripts/release/release.py dmg build/release/Roga.app dist/Roga-0.1.0.dmg --sign
    uv run Scripts/release/release.py notarize dist/Roga-0.1.0.dmg
    uv run Scripts/release/release.py appcast dist/Roga-0.1.0.zip --tag v0.1.0 --out dist

The publish workflow then writes the Homebrew cask with `cask`.

`archive --signing adhoc` builds without the Developer ID certificate, for
trying the packaging steps without it, and `rehearse` turns two such builds
into an update that can be tried on this Mac with no credentials at all.

The process is the one Errol uses, with two differences. Roga's code is in a
private repository, so the downloads go to the releases of a public one,
tmarkovski/roga-releases. And Sparkle's tools come from the package that
xcodebuild resolves for the app, so they're always the version the app links.

Credentials come from the environment in CI and from the keychain on a Mac:
notarizing reads NOTARY_KEY_P8 (base64), NOTARY_KEY_ID, and NOTARY_ISSUER_ID
when they're set, and otherwise the `roga-notary` profile that
`xcrun notarytool store-credentials` saves. The appcast is signed with Roga's
Sparkle key from the keychain, saved under the account `roga`, or from
standard input with `--key-file -`.
"""

import base64
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import click
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HERE = Path(__file__).parent
REPO = HERE.parent.parent
PROJECT = REPO / "Roga.xcodeproj"
DERIVED_DATA = REPO / "build/DerivedData"
SCHEME = "Roga"
APP_NAME = "Roga"
BUNDLE_ID = "sh.roga.app"
TEAM_ID = "JN3SN725AZ"
RELEASES_REPO = "tmarkovski/roga-releases"
WEBSITE = "https://roga.sh"
# Roga's Sparkle key is kept apart from other apps' keys, under its own
# account in the keychain.
SPARKLE_ACCOUNT = "roga"

# The distribution identity: TM Code & Co. LLC, the team Errol ships under too.
# These go to xcodebuild on the command line, where they beat the project's
# own settings for every target, the roga helper included, and leave local
# Xcode builds alone. A Developer ID signature ties the app's designated
# requirement to this team rather than to one certificate, so a new
# certificate is harmless, but changing the team after the first release would
# cost every installed copy the folders people let it read.
RELEASE_SETTINGS = [
    f"DEVELOPMENT_TEAM={TEAM_ID}",
    "CODE_SIGN_STYLE=Manual",
    "CODE_SIGN_IDENTITY=Developer ID Application",
    "PROVISIONING_PROFILE_SPECIFIER=",
    "ENABLE_HARDENED_RUNTIME=YES",
    "OTHER_CODE_SIGN_FLAGS=--timestamp",
]

# Where the two icons sit in the disk image's window, as points from its top
# left corner.
DMG_APP_AT = (150, 150)
DMG_APPLICATIONS_AT = (410, 150)


def run(*args: str | Path, check: bool = True, **kwargs) -> subprocess.CompletedProcess:
    """Runs a command, echoing it, and stops the release if it fails."""
    click.secho("$ " + " ".join(str(a) for a in args), fg="bright_black", err=True)
    result = subprocess.run([str(a) for a in args], **kwargs)
    if check and result.returncode != 0:
        for captured in (result.stdout, result.stderr):
            if captured:
                click.echo(captured if isinstance(captured, str) else captured.decode(errors="replace"), err=True)
        raise click.ClickException(f"{Path(str(args[0])).name} exited with {result.returncode}")
    return result


def bundle_info(archive_zip: Path) -> dict:
    """The Info.plist of the app inside an update ZIP."""
    return plistlib.loads(
        subprocess.run(
            ["unzip", "-p", str(archive_zip), f"{APP_NAME}.app/Contents/Info.plist"],
            capture_output=True,
            check=True,
        ).stdout
    )


@click.group()
def cli() -> None:
    """Build, sign, notarize, and package Roga."""


# --- archive -----------------------------------------------------------------


@cli.command()
@click.option("--version", "marketing", required=True, help="The version people see, like 0.1.0.")
@click.option("--build", "build", required=True, type=click.IntRange(min=1), help="The build number Sparkle compares.")
@click.option(
    "--signing",
    type=click.Choice(["developer-id", "adhoc"]),
    default="developer-id",
    show_default=True,
    help="developer-id for a release; adhoc signs with no certificate at all, as a CI runner without the secrets can.",
)
@click.option("--out", type=click.Path(file_okay=False, path_type=Path), required=True, help="Where Roga.app goes.")
def archive(marketing: str, build: int, signing: str, out: Path) -> None:
    """Archive the app and export Roga.app into OUT."""
    out.mkdir(parents=True, exist_ok=True)
    archive_path = out / f"{APP_NAME}.xcarchive"
    shutil.rmtree(archive_path, ignore_errors=True)
    settings = [f"MARKETING_VERSION={marketing}", f"CURRENT_PROJECT_VERSION={build}"]
    if signing == "developer-id":
        settings += RELEASE_SETTINGS
    else:
        settings += ["CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM="]
    run(
        "xcodebuild", "archive", "-quiet",
        "-project", PROJECT,
        "-scheme", SCHEME,
        "-configuration", "Release",
        "-destination", "generic/platform=macOS",
        "-derivedDataPath", DERIVED_DATA,
        "-onlyUsePackageVersionsFromResolvedFile",
        "-archivePath", archive_path,
        *settings,
    )  # fmt: skip

    app = out / f"{APP_NAME}.app"
    shutil.rmtree(app, ignore_errors=True)
    if signing == "developer-id":
        # Export re-signs everything inside the app, the roga helper and
        # Sparkle's helpers too, with the Developer ID certificate and a secure
        # timestamp.
        export = out / "export"
        shutil.rmtree(export, ignore_errors=True)
        options = out / "ExportOptions.plist"
        options.write_bytes(
            plistlib.dumps(
                {"method": "developer-id", "signingStyle": "manual", "teamID": TEAM_ID, "destination": "export"}
            )
        )
        run(
            "xcodebuild", "-exportArchive", "-quiet",
            "-archivePath", archive_path,
            "-exportOptionsPlist", options,
            "-exportPath", export,
        )  # fmt: skip
        (export / f"{APP_NAME}.app").rename(app)
        shutil.rmtree(export)
    else:
        run("ditto", archive_path / f"Products/Applications/{APP_NAME}.app", app)

    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    click.echo(f"wrote {app} ({info['CFBundleShortVersionString']}, build {info['CFBundleVersion']}, {signing})")


# --- notarize ----------------------------------------------------------------


def notary_credentials(profile: str, scratch: Path) -> list[str]:
    """The arguments that tell notarytool who is asking."""
    key = os.environ.get("NOTARY_KEY_P8")
    if key:
        key_id = os.environ.get("NOTARY_KEY_ID")
        issuer = os.environ.get("NOTARY_ISSUER_ID")
        if not key_id or not issuer:
            raise click.ClickException("NOTARY_KEY_P8 is set, but NOTARY_KEY_ID or NOTARY_ISSUER_ID is missing")
        path = scratch / "notary.p8"
        path.write_bytes(base64.b64decode(key))
        path.chmod(0o600)
        return ["--key", str(path), "--key-id", key_id, "--issuer", issuer]
    return ["--keychain-profile", profile]


@cli.command()
@click.argument("path", type=click.Path(exists=True, path_type=Path))
@click.option(
    "--keychain-profile",
    default="roga-notary",
    show_default=True,
    help="The notarytool profile to use when NOTARY_KEY_P8 isn't set.",
)
def notarize(path: Path, keychain_profile: str) -> None:
    """Notarize an app or a disk image and staple the ticket to it.

    An app goes up as a ZIP, since notarytool won't take a bundle, and the
    ticket is stapled to the app itself. That's why the ZIP for Sparkle is made
    afterwards: a ZIP can't carry a ticket, only an app inside it can.
    """
    if path.suffix not in (".app", ".dmg"):
        raise click.BadParameter("expected an .app or a .dmg", param_hint="PATH")
    with tempfile.TemporaryDirectory() as scratch_dir:
        scratch = Path(scratch_dir)
        upload = path
        if path.suffix == ".app":
            upload = scratch / f"{path.stem}.zip"
            run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", path, upload)
        credentials = notary_credentials(keychain_profile, scratch)
        # Not checked: a rejected submission exits nonzero, and its log is
        # what's worth seeing.
        result = run(
            "xcrun", "notarytool", "submit", upload, *credentials,
            "--wait", "--timeout", "30m", "--output-format", "json",
            check=False, capture_output=True, text=True,
        )  # fmt: skip
        try:
            submission = json.loads(result.stdout)
        except json.JSONDecodeError:
            click.echo(result.stdout + result.stderr, err=True)
            raise click.ClickException("notarytool didn't say what happened to the submission") from None
        click.echo(f"notarization {submission.get('id')}: {submission.get('status')}")
        if submission.get("status") != "Accepted":
            # The log says which file failed and why.
            if submission.get("id"):
                run("xcrun", "notarytool", "log", submission["id"], *credentials, check=False)
            raise click.ClickException(f"Apple did not accept {path.name}")
    run("xcrun", "stapler", "staple", path)
    run("xcrun", "stapler", "validate", path)


# --- zip and dmg ---------------------------------------------------------------


@cli.command("zip")
@click.argument("app", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.argument("output", type=click.Path(dir_okay=False, path_type=Path))
def zip_app(app: Path, output: Path) -> None:
    """Pack APP into the ZIP that Sparkle and Homebrew download."""
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, output)
    click.echo(f"wrote {output}")


def developer_id_identity() -> str:
    """The SHA-1 of the one Developer ID Application identity for the team."""
    listing = run("security", "find-identity", "-v", "-p", "codesigning", capture_output=True, text=True).stdout
    matches = [
        line.split()[1]
        for line in listing.splitlines()
        if '"Developer ID Application:' in line and f"({TEAM_ID})" in line
    ]
    if len(matches) != 1:
        raise click.ClickException(
            f"expected one Developer ID Application identity for {TEAM_ID} in the keychain, found {len(matches)}"
        )
    return matches[0]


@cli.command()
@click.argument("app", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.argument("output", type=click.Path(dir_okay=False, path_type=Path))
@click.option("--volume-name", default=APP_NAME, show_default=True, help="The name the mounted image shows in Finder.")
@click.option("--sign", is_flag=True, help="Sign the image with the team's Developer ID Application certificate.")
def dmg(app: Path, output: Path, volume_name: str, sign: bool) -> None:
    """Pack APP into the disk image people download from the website.

    The image opens to a Finder window with the app on the left and a link to
    Applications on the right. dmgbuild writes the window's layout into the
    image itself, so this works the same on a CI runner with no Finder. Errol's
    image has a background showing which way to drag; Roga's doesn't have one
    yet.
    """
    # Imported here, so that the publish workflow can write the cask on Linux.
    import dmgbuild

    icon = app / "Contents/Resources/AppIcon.icns"
    if not icon.exists():
        raise click.ClickException(f"{icon} is missing, so the image would have no icon")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.unlink(missing_ok=True)
    settings = {
        # LZFSE compression: smaller than zlib and quick to open.
        "format": "ULFO",
        "files": [str(app)],
        "symlinks": {"Applications": "/Applications"},
        # The mounted volume shows the app's own icon.
        "icon": str(icon),
        "icon_locations": {app.name: DMG_APP_AT, "Applications": DMG_APPLICATIONS_AT},
        # No hide_extensions: it marks the bundle with Finder information,
        # which fails `codesign --verify --strict`. Finder hides ".app" anyway
        # unless someone has chosen to see every extension.
        #
        # The height counts the title bar, which is 32 points on macOS 26 and 27.
        "window_rect": ((200, 140), (560, 332)),
        "default_view": "icon-view",
        "icon_size": 112,
        "text_size": 13,
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
    }
    dmgbuild.build_dmg(str(output), volume_name, settings=settings)
    if sign:
        run("codesign", "--sign", developer_id_identity(), "--timestamp", output)
    click.echo(f"wrote {output}")


# --- appcast -------------------------------------------------------------------


def sparkle_tools() -> Path:
    """Sparkle's bin/ folder, from the package xcodebuild resolves for the app.

    Swift Package Manager checks the download against the checksum in Sparkle's
    own manifest, and the version is the one pinned in Package.resolved, so the
    tools always match the framework the app links.
    """
    tools = DERIVED_DATA / "SourcePackages/artifacts/sparkle/Sparkle/bin"
    if not (tools / "generate_appcast").exists():
        run(
            "xcodebuild", "-resolvePackageDependencies", "-quiet",
            "-project", PROJECT,
            "-scheme", SCHEME,
            "-derivedDataPath", DERIVED_DATA,
            "-onlyUsePackageVersionsFromResolvedFile",
        )  # fmt: skip
    if not (tools / "generate_appcast").exists():
        raise click.ClickException(f"Sparkle's tools aren't in {tools} after resolving the packages")
    return tools


def published_releases(limit: int) -> list[str]:
    """Tags of the newest published releases, leaving out drafts and prereleases."""
    listing = run(
        "gh", "release", "list", "--repo", RELEASES_REPO,
        "--exclude-drafts", "--exclude-pre-releases",
        "--limit", str(limit), "--json", "tagName",
        capture_output=True, text=True,
    )  # fmt: skip
    return [release["tagName"] for release in json.loads(listing.stdout)]


@cli.command()
@click.argument("archive_zip", metavar="ZIP", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option("--tag", required=True, help="The tag of the release the ZIP will be uploaded to, like v0.1.0.")
@click.option(
    "--out",
    type=click.Path(file_okay=False, path_type=Path),
    required=True,
    help="Where appcast.xml and the deltas go.",
)
@click.option(
    "--notes",
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Release notes in Markdown, shown in the update window.",
)
@click.option(
    "--key-file",
    help="The private Sparkle key: a path, or - to read it from standard input. "
    f"Without it, the key comes from the keychain's {SPARKLE_ACCOUNT!r} account.",
)
@click.option(
    "--previous", default=3, show_default=True, help="How many published releases to build delta updates from."
)
@click.option(
    "--include",
    multiple=True,
    type=click.Path(exists=True, dir_okay=False, path_type=Path),
    help="Another update ZIP to put in the feed, for a rehearsal that doesn't use GitHub.",
)
@click.option(
    "--download-url-prefix",
    help="Where the ZIP and deltas will be downloadable, ending in a slash. Defaults to the tag's release on GitHub.",
)
def appcast(
    archive_zip: Path,
    tag: str,
    out: Path,
    notes: Path | None,
    key_file: str | None,
    previous: int,
    include: tuple[Path, ...],
    download_url_prefix: str | None,
) -> None:
    """Write the update feed that offers ZIP, with deltas from earlier releases.

    The feed starts from the one in the newest published release, so earlier
    entries keep their own download links, and the new entry and its deltas
    point at TAG. Upload appcast.xml and every .delta file from OUT to that
    release alongside the ZIP.
    """
    tools = sparkle_tools()
    prefix = download_url_prefix or f"https://github.com/{RELEASES_REPO}/releases/download/{tag}/"
    out.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as work_dir:
        work = Path(work_dir)
        for archive_file in (archive_zip, *include):
            shutil.copy2(archive_file, work / archive_file.name)
        if notes:
            shutil.copy2(notes, work / f"{archive_zip.stem}.md")
        tags = published_releases(previous) if download_url_prefix is None else []
        for index, earlier in enumerate(tags):
            # Only the newest feed is wanted; the ZIPs are there for deltas.
            patterns = ["--pattern", f"{APP_NAME}-*.zip"] + (["--pattern", "appcast.xml"] if index == 0 else [])
            fetched = run(
                "gh", "release", "download", earlier, "--repo", RELEASES_REPO, "--dir", work, "--skip-existing",
                *patterns, check=False,
            )  # fmt: skip
            if fetched.returncode != 0:
                click.secho(f"couldn't download from {earlier}; the feed won't have its deltas", fg="yellow", err=True)

        command = [
            tools / "generate_appcast",
            "--download-url-prefix", prefix,
            "--link", WEBSITE,
            "--full-release-notes-url", f"https://github.com/{RELEASES_REPO}/releases",
            # Without it the notes become a link built on --link, roga.sh/<zip>.md,
            # which the site answers with its 404 page, shown raw in the window.
            "--embed-release-notes",
            "--maximum-deltas", str(previous),
        ]  # fmt: skip
        command += ["--ed-key-file", key_file] if key_file else ["--account", SPARKLE_ACCOUNT]
        command.append(work)
        # With --key-file -, the key arrives on this process's standard input
        # and passes straight through, so it's never written to disk.
        run(*command)

        feed = work / "appcast.xml"
        text = feed.read_text()
        build = bundle_info(archive_zip)["CFBundleVersion"]
        if f"{prefix}{archive_zip.name}" not in text or f"<sparkle:version>{build}</sparkle:version>" not in text:
            raise click.ClickException(f"the feed has no entry for build {build} at {prefix}{archive_zip.name}")
        shutil.copy2(feed, out / "appcast.xml")
        deltas = sorted(work.glob("*.delta"))
        for delta in deltas:
            shutil.copy2(delta, out / delta.name)
    click.echo(f"wrote {out / 'appcast.xml'} and {len(deltas)} delta update(s) for build {build}")


# --- cask ----------------------------------------------------------------------


@cli.command()
@click.argument("archive_zip", metavar="ZIP", type=click.Path(exists=True, dir_okay=False, path_type=Path))
@click.option("--out", type=click.Path(dir_okay=False, path_type=Path), required=True, help="Where to write roga.rb.")
def cask(archive_zip: Path, out: Path) -> None:
    """Write the Homebrew cask that installs the release whose ZIP this is.

    The ZIP must be the one uploaded to the release, since the cask holds its
    checksum. The publish workflow downloads it from there before calling this.
    """
    info = bundle_info(archive_zip)
    version = info["CFBundleShortVersionString"]
    if archive_zip.name != f"{APP_NAME}-{version}.zip":
        raise click.ClickException(
            f"{archive_zip.name} holds version {version}, so it should be {APP_NAME}-{version}.zip"
        )
    sha256 = hashlib.sha256(archive_zip.read_bytes()).hexdigest()
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(
        f"""cask "roga" do
  version "{version}"
  sha256 "{sha256}"

  url "https://github.com/{RELEASES_REPO}/releases/download/v#{{version}}/{APP_NAME}-#{{version}}.zip",
      verified: "github.com/{RELEASES_REPO}/"
  name "Roga"
  desc "Native Git client for reviewing what your agents wrote"
  homepage "{WEBSITE}/"

  livecheck do
    url "{WEBSITE}/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :tahoe

  app "{APP_NAME}.app"

  zap trash: [
    "~/Library/Application Support/{BUNDLE_ID}",
    "~/Library/Caches/{BUNDLE_ID}",
    "~/Library/HTTPStorages/{BUNDLE_ID}",
    "~/Library/Preferences/{BUNDLE_ID}.plist",
    "~/Library/Saved Application State/{BUNDLE_ID}.savedState",
  ]
end
"""
    )
    click.echo(f"wrote {out} for {version}")


# --- rehearse ------------------------------------------------------------------


REHEARSAL_PORT = 8765
# The rehearsal's copies have a bundle identifier of their own, so they keep
# their own settings and Application Support folder, and never touch the
# window sizes, repositories or hooks of the Roga someone uses every day.
REHEARSAL_BUNDLE_ID = "sh.roga.test.update"


def prepare_rehearsal_copy(app: Path, public_key: str, feed_url: str) -> None:
    """Makes a copy trust the rehearsal's key and feed, under its own identity, and signs it again ad hoc."""
    plist = app / "Contents/Info.plist"
    run("plutil", "-replace", "CFBundleIdentifier", "-string", REHEARSAL_BUNDLE_ID, plist)
    run("plutil", "-replace", "SUFeedURL", "-string", feed_url, plist)
    run("plutil", "-replace", "SUPublicEDKey", "-string", public_key, plist)
    run("codesign", "--force", "--deep", "--sign", "-", app)
    run("codesign", "--verify", "--deep", "--strict", app)


@cli.command()
@click.argument("old", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.argument("new", type=click.Path(exists=True, file_okay=False, path_type=Path))
@click.option(
    "--work",
    type=click.Path(file_okay=False, path_type=Path),
    required=True,
    help="A scratch folder for the rehearsal.",
)
@click.option("--serve/--no-serve", default=True, show_default=True, help="Serve the feed until interrupted.")
def rehearse(old: Path, new: Path, work: Path, serve: bool) -> None:
    """Rehearse an update from OLD to NEW on this Mac, with no credentials.

    OLD and NEW are two builds from `archive --signing adhoc`, NEW with the
    higher build number. This gives both copies the bundle identifier
    sh.roga.test.update, makes them trust a throwaway Sparkle key and a feed
    served from http://127.0.0.1:8765, writes that feed for NEW with a delta
    from OLD, installs OLD in WORK/install, and serves the feed.
    """
    shutil.rmtree(work, ignore_errors=True)
    feed_dir, install, key_dir = work / "feed", work / "install", work / "key"
    for folder in (feed_dir, install, key_dir):
        folder.mkdir(parents=True)

    # Sparkle keeps a private key as the base64 of its 32-byte seed.
    seed = os.urandom(32)
    public = Ed25519PrivateKey.from_private_bytes(seed).public_key()
    public_key = base64.b64encode(
        public.public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    ).decode()
    private_file = key_dir / "private.key"
    private_file.write_text(base64.b64encode(seed).decode())
    private_file.chmod(0o600)

    prefix = f"http://127.0.0.1:{REHEARSAL_PORT}/"
    versions = []
    for label, app in (("old", old), ("new", new)):
        copy = work / label / app.name
        run("ditto", app, copy)
        prepare_rehearsal_copy(copy, public_key, f"{prefix}appcast.xml")
        info = plistlib.loads((copy / "Contents/Info.plist").read_bytes())
        versions.append((copy, info["CFBundleShortVersionString"], int(info["CFBundleVersion"])))
    (old_app, old_version, old_build), (new_app, new_version, new_build) = versions
    if new_build <= old_build:
        raise click.ClickException(f"NEW is build {new_build}, which doesn't come after OLD's {old_build}")

    old_zip = work / f"{APP_NAME}-{old_version}.zip"
    new_zip = work / f"{APP_NAME}-{new_version}.zip"
    zip_app.callback(app=old_app, output=old_zip)
    zip_app.callback(app=new_app, output=new_zip)
    dmg.callback(app=old_app, output=feed_dir / f"{APP_NAME}-{old_version}.dmg", volume_name=APP_NAME, sign=False)
    appcast.callback(
        archive_zip=new_zip,
        tag=f"v{new_version}",
        out=feed_dir,
        notes=None,
        key_file=str(private_file),
        previous=3,
        include=(old_zip,),
        download_url_prefix=prefix,
    )
    shutil.copy2(new_zip, feed_dir / new_zip.name)
    run("ditto", old_app, install / old_app.name)

    click.echo(
        f"""
Ready to rehearse the update from {old_version} (build {old_build}) to {new_version} (build {new_build}).

  1. Open {install / old_app.name}.
     It has never checked, so Sparkle checks at once, and the notice shows at
     the top of the sidebar. Choose it and install the update.
  2. To try Restart to Update instead, quit it, turn on downloading and clear
     the last check, and open it again:
       defaults write {REHEARSAL_BUNDLE_ID} SUAutomaticallyUpdate -bool true
       defaults delete {REHEARSAL_BUNDLE_ID} SULastCheckTime
  3. Afterwards, delete the rehearsal's settings and folders:
       defaults delete {REHEARSAL_BUNDLE_ID}
       rm -rf ~/Library/Caches/{REHEARSAL_BUNDLE_ID} ~/Library/"Application Support"/{REHEARSAL_BUNDLE_ID}
"""
    )
    if serve:
        click.echo(f"serving {feed_dir} at {prefix} until interrupted")
        run(sys.executable, "-m", "http.server", str(REHEARSAL_PORT), "--bind", "127.0.0.1", "--directory", feed_dir)


if __name__ == "__main__":
    sys.exit(cli())
