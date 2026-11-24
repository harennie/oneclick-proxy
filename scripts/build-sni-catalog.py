#!/usr/bin/env python3
"""Build the bundled SNI catalog from public, versioned lists of official sites."""

import argparse
import csv
import io
import json
import re
import zipfile
from collections import defaultdict
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
HOSTNAME = re.compile(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}")
MAX_PER_COUNTRY = 40


class M49Table(HTMLParser):
    def __init__(self):
        super().__init__()
        self.regions = {}
        self.row = []
        self.cell = None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag == "td":
            self.cell = ""

    def handle_data(self, data):
        if self.cell is not None:
            self.cell += data

    def handle_endtag(self, tag):
        if tag == "td" and self.cell is not None:
            self.row.append(self.cell.strip())
            self.cell = None
        elif tag == "tr" and len(self.row) >= 12:
            code, subregion = self.row[10], self.row[6] or self.row[4]
            if re.fullmatch(r"[A-Z]{2}", code) and re.fullmatch(r"\d{3}", subregion):
                self.regions[code] = subregion


def normalize_site(url, black_labels, black_domains):
    try:
        site = urlsplit(url.strip())
        host = (site.hostname or "").rstrip(".").encode("idna").decode("ascii").lower()
        port = site.port
    except (UnicodeError, ValueError):
        return None
    if site.scheme not in ("https", "http") or site.username or port not in (None, 443, 80):
        return None
    if len(host) > 253 or not HOSTNAME.fullmatch(host):
        return None
    if host.endswith(".cn") or black_labels.intersection(host.split(".")):
        return None
    if any(host == domain or host.endswith("." + domain) for domain in black_domains):
        return None
    return host, site


def ror_websites(path):
    with zipfile.ZipFile(path) as archive:
        csv_name = next(name for name in archive.namelist() if name.endswith(".csv"))
        with archive.open(csv_name) as file:
            rows = csv.DictReader(io.TextIOWrapper(file, encoding="utf-8-sig"))
            for row in rows:
                if row["status"] != "active":
                    continue
                countries = re.split(r"[|;]", row["locations.geonames_details.country_code"])
                websites = re.split(r"[|;]", row["links.type.website"])
                for country in countries:
                    for website in websites:
                        yield country.strip(), website, row["types"]


def supplemental_websites(path):
    with path.open(encoding="utf-8-sig", newline="") as file:
        for row in csv.DictReader(file):
            yield row["country"], row["website"], ""


def build_catalog(args):
    countries = json.loads(args.iso.read_text(encoding="utf-8-sig"))["3166-1"]
    m49 = M49Table()
    m49.feed(args.m49.read_text(encoding="utf-8-sig"))
    if len(countries) < 240 or len(m49.regions) < 230:
        raise ValueError("ISO or M49 input is missing most of the country codes")
    # The M49 overview does not give Taiwan a separate row.
    m49.regions.setdefault("TW", "030")
    countries = {row["alpha_2"]: m49.regions.get(row["alpha_2"], "000") for row in countries}

    selection_code = (ROOT / "src/xray.sh").read_text(encoding="utf-8")
    black_labels, black_domains = (
        set(re.search(rf'^{key}="([^"]*)"', selection_code, re.MULTILINE)[1].split())
        for key in ("SNI_BLACK_LABELS", "SNI_BLACK_DOMAINS")
    )
    sites = defaultdict(dict)
    sources = [ror_websites(args.ror)]
    sources.extend(supplemental_websites(path) for path in args.supplement)
    for websites in sources:
        for country, url, types in websites:
            if country not in countries:
                continue
            normalized = normalize_site(url, black_labels, black_domains)
            if not normalized:
                continue
            host, site = normalized
            suffix = "uk" if country == "GB" else country.lower()
            priority = (
                not host.endswith("." + suffix),
                site.scheme != "https",
                site.path not in ("", "/"),
                "education" not in types,
                host,
            )
            key = host.removeprefix("www.")
            if key not in sites[country] or priority < sites[country][key]:
                sites[country][key] = priority

    catalog = []
    for country, subregion in sorted(countries.items()):
        hosts = [site[-1] for site in sorted(sites[country].values())[:MAX_PER_COUNTRY]]
        catalog.append((country, subregion, hosts))
    return catalog


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--iso", required=True, type=Path)
    parser.add_argument("--m49", required=True, type=Path)
    parser.add_argument("--ror", required=True, type=Path)
    parser.add_argument("--supplement", action="append", default=[], type=Path, help="CSV with country,website columns")
    parser.add_argument("--verified", type=Path, help="TSV with country_code,local_vps_verified columns")
    args = parser.parse_args()
    catalog = build_catalog(args)
    verified = {}
    if args.verified:
        with args.verified.open(encoding="utf-8", newline="") as file:
            verified = {
                row["country_code"]: int(row["local_vps_verified"])
                for row in csv.DictReader(file, delimiter="\t")
                if row["local_vps_verified"].isdecimal()
            }

    rows = [
        "# Generated by scripts/build-sni-catalog.py",
        "# Country or area | UN M49 subregion | official website hostnames to probe",
        "sni_catalog() {",
        "  cat <<'SNI_CATALOG'",
        *(f"{country}|{subregion}|{' '.join(hosts)}" for country, subregion, hosts in catalog),
        "SNI_CATALOG",
        "}",
    ]
    (ROOT / "src/sni-catalog.sh").write_text("\n".join(rows) + "\n", encoding="utf-8", newline="\n")
    with (ROOT / "data/sni-coverage.tsv").open("w", encoding="utf-8", newline="") as file:
        report = csv.writer(file, delimiter="\t", lineterminator="\n")
        report.writerow(("country_code", "m49_subregion", "catalog_candidates", "local_vps_verified"))
        report.writerows((country, subregion, len(hosts), verified.get(country, "pending")) for country, subregion, hosts in catalog)
    print(f"{len(catalog)} countries and areas, {sum(len(hosts) for _, _, hosts in catalog)} candidate hostnames")


if __name__ == "__main__":
    main()
