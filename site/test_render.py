import io
import json
import pathlib
import shutil
import tempfile
import unittest

import render

FIXTURE = pathlib.Path(__file__).with_name("testdata") / "index-v2.json"
REPO_LINK = "fdroidrepos://example.invalid/fdroid/repo?fingerprint=ABC"


def index():
    return json.loads(FIXTURE.read_text())


def icon_stub(app):
    return "icon:" + app.package


class PickApk(unittest.TestCase):
    def test_prefers_arm64_over_a_higher_version_code(self):
        versions = index()["packages"]["org.example.trap"]["versions"].values()
        picked = render.pick_apk(versions)
        self.assertEqual(8002, picked["manifest"]["versionCode"])
        self.assertEqual("/trap-8002-arm64-v8a-release.apk", picked["file"]["name"])

    def test_universal_apk_qualifies(self):
        versions = index()["packages"]["org.example.universal"]["versions"].values()
        self.assertEqual(4, render.pick_apk(versions)["manifest"]["versionCode"])

    def test_version_without_nativecode_qualifies(self):
        versions = index()["packages"]["org.example.nativeless"]["versions"].values()
        self.assertEqual(7, render.pick_apk(versions)["manifest"]["versionCode"])

    def test_returns_none_when_no_build_fits_arm64(self):
        versions = index()["packages"]["org.example.x86only"]["versions"].values()
        self.assertIsNone(render.pick_apk(versions))


class LoadApps(unittest.TestCase):
    def test_skips_apps_without_an_arm64_build(self):
        packages = [app.package for app in render.load_apps(index())]
        self.assertNotIn("org.example.x86only", packages)

    def test_orders_by_the_day_the_app_entered_the_repo(self):
        packages = [app.package for app in render.load_apps(index())]
        self.assertEqual(
            ["org.example.trap", "org.example.universal", "org.example.nativeless"],
            packages,
        )

    def test_reads_name_summary_licence_and_source(self):
        app = render.load_apps(index())[0]
        self.assertEqual("Trap", app.name)
        self.assertEqual("Highest versionCode is the x86_64 split", app.summary)
        self.assertEqual("GPL-3.0-only", app.license)
        self.assertEqual("https://example.invalid/trap", app.source)

    def test_a_zero_major_version_is_a_pre_release(self):
        by_package = {app.package: app for app in render.load_apps(index())}
        self.assertTrue(by_package["org.example.universal"].prerelease)
        self.assertFalse(by_package["org.example.trap"].prerelease)


class RenderTiles(unittest.TestCase):
    def tiles(self):
        return render.render_tiles(render.load_apps(index()), REPO_LINK, icon_stub)

    def test_links_the_apk_below_the_repo_path(self):
        self.assertIn('href="/fdroid/repo/trap-8002-arm64-v8a-release.apk"', self.tiles())

    def test_names_the_download_size_in_mib(self):
        self.assertIn("31 MiB", self.tiles())

    def test_shows_the_version_of_the_apk_it_links(self):
        self.assertIn(">v1.4.0<", self.tiles())

    def test_carries_the_package_id_for_the_index_lookup(self):
        self.assertIn('data-pkg="org.example.trap"', self.tiles())

    def test_badge_points_at_the_repo_link_of_the_template(self):
        self.assertIn('href="%s"' % REPO_LINK, self.tiles())

    def test_renders_one_tile_per_app(self):
        self.assertEqual(3, self.tiles().count('class="app"'))

    def test_escapes_html_in_metadata(self):
        raw = index()
        raw["packages"]["org.example.trap"]["metadata"]["summary"]["en-US"] = 'a <b> & "q"'
        tiles = render.render_tiles(render.load_apps(raw), REPO_LINK, icon_stub)
        self.assertNotIn("a <b> &", tiles)
        self.assertIn("&lt;b&gt;", tiles)


class RenderTable(unittest.TestCase):
    def table(self):
        return render.render_table(render.load_apps(index()))

    def test_one_row_per_app(self):
        self.assertEqual(3, len([r for r in self.table().splitlines() if r.startswith("|")]))

    def test_marks_a_pre_release(self):
        self.assertIn("0.3.0 (pre-release)", self.table())

    def test_links_the_source(self):
        self.assertIn("https://example.invalid/trap", self.table())


class ReplaceRegion(unittest.TestCase):
    TEXT = "head\n<!-- apps:begin -->\nold\n<!-- apps:end -->\ntail\n"

    def test_replaces_only_between_the_markers(self):
        out = render.replace_region(self.TEXT, "new")
        self.assertIn("head\n", out)
        self.assertIn("tail\n", out)
        self.assertIn("new", out)
        self.assertNotIn("old", out)

    def test_is_idempotent(self):
        once = render.replace_region(self.TEXT, "new")
        self.assertEqual(once, render.replace_region(once, "new"))

    def test_refuses_a_text_without_markers(self):
        with self.assertRaises(render.MarkerError):
            render.replace_region("no markers here", "new")


class Icons(unittest.TestCase):
    def png(self, size):
        from PIL import Image

        directory = pathlib.Path(tempfile.mkdtemp())
        path = directory / "icon.png"
        Image.new("RGBA", (size, size), (200, 90, 40, 255)).save(path)
        self.addCleanup(shutil.rmtree, directory)
        return path

    def test_scales_an_oversized_icon_down_to_the_box_it_is_shown_in(self):
        from PIL import Image

        path = self.png(512)
        scaled = render.scaled_png(path)
        with Image.open(io.BytesIO(scaled)) as image:
            self.assertEqual(render.ICON_PX, max(image.size))
        self.assertLess(len(scaled), path.stat().st_size)

    def test_leaves_an_icon_that_already_fits_untouched(self):
        path = self.png(64)
        self.assertEqual(path.read_bytes(), render.scaled_png(path))

    def test_falls_back_to_a_repo_url_when_the_icon_file_is_missing(self):
        app = render.load_apps(index())[0]._replace(icon_path="/nowhere/icon.png")
        self.assertEqual("/fdroid/repo/nowhere/icon.png", render.data_uri_icon(app))


if __name__ == "__main__":
    unittest.main()
