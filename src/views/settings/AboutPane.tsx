/** Community release links and original author credits. Updates are installed manually. */
import { useEffect, useState, type SVGProps } from "react";
import { Github, Globe, Heart, Instagram, Twitch } from "lucide-react";

import { getBackend } from "@/ipc/client";
import { FORK_RELEASES, FORK_REPOSITORY } from "@/lib/forkLinks";


import layout from "./PaneLayout.module.css";
import styles from "./Preferences.module.css";
import { Button, Toggle } from "./controls";


// Discord brand mark from Simple Icons (CC0).
function DiscordIcon({ size = 19, ...props }: SVGProps<SVGSVGElement> & { size?: number }) {
  return <svg {...props} width={size} height={size} viewBox="0 0 24 24" fill="currentColor">
    <path d="M20.317 4.3698a19.7913 19.7913 0 00-4.8851-1.5152.0741.0741 0 00-.0785.0371c-.211.3753-.4447.8648-.6083 1.2495-1.8447-.2762-3.68-.2762-5.4868 0-.1636-.3933-.4058-.8742-.6177-1.2495a.077.077 0 00-.0785-.037 19.7363 19.7363 0 00-4.8852 1.515.0699.0699 0 00-.0321.0277C.5334 9.0458-.319 13.5799.0992 18.0578a.0824.0824 0 00.0312.0561c2.0528 1.5076 4.0413 2.4228 5.9929 3.0294a.0777.0777 0 00.0842-.0276c.4616-.6304.8731-1.2952 1.226-1.9942a.076.076 0 00-.0416-.1057c-.6528-.2476-1.2743-.5495-1.8722-.8923a.077.077 0 01-.0076-.1277c.1258-.0943.2517-.1923.3718-.2914a.0743.0743 0 01.0776-.0105c3.9278 1.7933 8.18 1.7933 12.0614 0a.0739.0739 0 01.0785.0095c.1202.099.246.1981.3728.2924a.077.077 0 01-.0066.1276 12.2986 12.2986 0 01-1.873.8914.0766.0766 0 00-.0407.1067c.3604.698.7719 1.3628 1.225 1.9932a.076.076 0 00.0842.0286c1.961-.6067 3.9495-1.5219 6.0023-3.0294a.077.077 0 00.0313-.0552c.5004-5.177-.8382-9.6739-3.5485-13.6604a.061.061 0 00-.0312-.0286zM8.02 15.3312c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9555-2.4189 2.157-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.9555 2.4189-2.1569 2.4189zm7.9748 0c-1.1825 0-2.1569-1.0857-2.1569-2.419 0-1.3332.9554-2.4189 2.1569-2.4189 1.2108 0 2.1757 1.0952 2.1568 2.419 0 1.3332-.946 2.4189-2.1568 2.4189Z" />
  </svg>;
}

// TikTok brand mark from Simple Icons (CC0).
function TikTokIcon({ size = 19, ...props }: SVGProps<SVGSVGElement> & { size?: number }) {
  return <svg {...props} width={size} height={size} viewBox="0 0 24 24" fill="currentColor">
    <path d="M12.525.02c1.31-.02 2.61-.01 3.91-.02.08 1.53.63 3.09 1.75 4.17 1.12 1.11 2.7 1.62 4.24 1.79v4.03c-1.44-.05-2.89-.35-4.2-.97-.57-.26-1.1-.59-1.62-.93-.01 2.92.01 5.84-.02 8.75-.08 1.4-.54 2.79-1.35 3.94-1.31 1.92-3.58 3.17-5.91 3.21-1.43.08-2.86-.31-4.08-1.03-2.02-1.19-3.44-3.37-3.65-5.71-.02-.5-.03-1-.01-1.49.18-1.9 1.12-3.72 2.58-4.96 1.66-1.44 3.98-2.13 6.15-1.72.02 1.48-.04 2.96-.04 4.44-.99-.32-2.15-.23-3.02.37-.63.41-1.11 1.04-1.36 1.75-.21.51-.15 1.07-.14 1.61.24 1.64 1.82 3.02 3.5 2.87 1.12-.01 2.19-.66 2.77-1.61.19-.33.4-.67.41-1.06.1-1.79.06-3.57.07-5.36.01-4.03-.01-8.05.02-12.07z" />
  </svg>;
}

/** Where the links go. */
export const ABOUT_LINKS = [
  { label: "Instagram", Icon: Instagram, url: "https://instagram.com/triodeofficial" },
  { label: "TikTok", Icon: TikTokIcon, url: "https://www.tiktok.com/@triodeofficial" },
  { label: "Twitch", Icon: Twitch, url: "https://twitch.tv/triodeofficial" },
  { label: "Discord", Icon: DiscordIcon, url: "https://discord.gg/vUkcYZhwuR" },
  { label: "GitHub", Icon: Github, url: FORK_REPOSITORY },
  { label: "Web", Icon: Globe, url: "https://triodeofficial.com" },
];

const SUPPORT_URL = "https://www.paypal.com/donate/?hosted_button_id=H6GGU8PHP8CJE";

export function AboutPane() {
  const [version, setVersion] = useState<string | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let live = true;
    void getBackend().then(backend => backend.appVersion()).then(value => { if (live) setVersion(value); }).catch(() => {});
    return () => { live = false; };
  }, []);
  const open = (url: string) => {
    setError("");
    void getBackend().then(backend => backend.openUrl(url)).catch(() => setError("Could not open your browser. Visit github.com/computergabe/rbxport."));
  };
  return (
    <>
      <section className={styles.section} aria-label="About">
        <div className={styles.aboutHeader}>
          <div>
            <h1 className={styles.aboutName}>rbxport</h1>
            <p className={styles.aboutVersion} data-testid="about-version">v{version ?? "—"}</p>
          </div>
          <Button onClick={() => open(FORK_RELEASES)}>Check for updates</Button>
        </div>
        <div className={styles.aboutUpdates}>
          <Toggle label="Download updates" checked={false} disabled onChange={() => {}} />
          <p className={layout.help}>In-app installation is disabled. Check for updates opens this fork's releases in your browser. Download and install a release manually.</p>
          {error ? <p role="alert">{error}</p> : null}
        </div>        <div className={styles.aboutSupport}>
          <h2>Support rbxport</h2>
          <p>rbxport is free to use and independently developed by TRIODE.</p>
          <p>If it makes your DJ workflow easier, consider supporting continued development and future features.</p>
          <Button className={styles.supportButton} onClick={() => open(SUPPORT_URL)}><Heart className={styles.supportHeart} size={16} aria-hidden="true" /> Support rbxport</Button>
        </div>
      </section>
      <div className={styles.aboutLegal}>
        <details>
          <summary>Licence</summary>
          <p className={styles.aboutLine}>
            rbxport is free software, licensed under the GNU General Public License version 2 or, at your
            option, any later version. It comes with no warranty. It includes the Rubber Band Library
            by Particular Programs Ltd., under the same licence.
          </p>
        </details>
        <details>
          <summary>Disclaimer</summary>
          <p className={styles.aboutLine}>
            rbxport is an independent project and is not affiliated with, endorsed by, or sponsored by
            AlphaTheta Corporation, Pioneer DJ, or any other third party. rekordbox, CDJ, XDJ and
            PRO DJ LINK are trademarks of their respective owners. Back up your library before using
            any feature that writes to it.
          </p>
        </details>
      </div>
      <footer className={styles.aboutFoot}>
        <div className={styles.aboutLinks} role="group" aria-label="Author links">
          {ABOUT_LINKS.map(({ label, url, Icon }) => (
            <button key={label} type="button" className={styles.aboutSocial} aria-label={label} title={label} onClick={() => open(url)}>
              <Icon size={19} aria-hidden="true" />
            </button>
          ))}
        </div>
        <p className={styles.aboutMade}><span>Made by TRIODE with</span> <Heart className={styles.supportHeart} size="1em" aria-hidden="true" /> <span>in California</span></p>
      </footer>
    </>
  );
}
