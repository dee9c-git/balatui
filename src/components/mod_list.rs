use super::{Component, Eventable};
use crate::components::about::About;
use balatui::{RemoteMod, install_dir, reinstall_mod};
use color_eyre::Result;
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use log::{error, info};
use notify::recommended_watcher;
use notify::{Event, RecursiveMode, Watcher};
use ratatui::layout::Margin;
use ratatui::style::Color;
use ratatui::{
    Frame,
    layout::{Constraint, Flex, Layout, Rect},
    style::Style,
};
use tokio::sync::mpsc;
use tokio::sync::mpsc::UnboundedSender;

use crate::action::Action;
use crate::components::option_selector::{Actions, OptionSelector, OptionSelectorText};
use crate::mods::{Mod, ModList, is_same_mod};

pub struct ModlistComponent {
    pub action_tx: Option<UnboundedSender<Action>>,
    pub has_focus: bool,
    options: OptionSelector,
    mods: Vec<Mod>,
    catalog: Vec<RemoteMod>,
    local_action_tx: mpsc::UnboundedSender<Actions>,
    local_action_rx: mpsc::UnboundedReceiver<Actions>,
}

impl ModlistComponent {
    pub fn new() -> Self {
        let mut installed_mod_selector = OptionSelector::new(vec![]);
        installed_mod_selector.title = "Installed mods".to_string();
        installed_mod_selector.flex = Flex::Center;

        let mods_ref = Vec::new();

        let (modlist_tx, modlist_rx) = tokio::sync::mpsc::unbounded_channel();

        let mut this = Self {
            action_tx: None,
            has_focus: false,
            options: installed_mod_selector,
            mods: mods_ref,
            catalog: Vec::new(),
            local_action_rx: modlist_rx,
            local_action_tx: modlist_tx,
        };

        this.mods = ModList::get_local_mods();
        this.build_options();

        let mod_dir = ModList::get_local_mod_dir().as_path().to_path_buf();
        if let Err(e) = std::fs::create_dir_all(&mod_dir) {
            log::error!("Failed to create mod directory {}: {}", mod_dir.display(), e);
        }
        let local_action_tx_clone = this.local_action_tx.clone();

        std::thread::spawn(move || {
            let mut watcher = match recommended_watcher(
                move |res: std::result::Result<Event, notify::Error>| match res {
                    Ok(event) => match event {
                        Event {
                            kind: notify::event::EventKind::Create(_),
                            ..
                        }
                        | Event {
                            kind: notify::event::EventKind::Remove(_),
                            ..
                        }
                        | Event {
                            kind: notify::event::EventKind::Modify(_),
                            ..
                        } => {
                            let _ = local_action_tx_clone.send(Actions::Reload);
                        }
                        _ => {}
                    },
                    Err(e) => {
                        log::error!("watch error: {:?}", e);
                    }
                },
            ) {
                Ok(w) => w,
                Err(e) => {
                    log::error!("Failed to create watcher: {}", e);
                    return;
                }
            };

            if let Err(e) = watcher.watch(&mod_dir, RecursiveMode::NonRecursive) {
                log::error!("Failed to watch mod directory {}: {}", mod_dir.display(), e);
            }

            // Keep the thread alive
            loop {
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        });

        this
    }
    pub fn update_catalog(&mut self, catalog: Vec<RemoteMod>) {
        self.catalog = catalog;
    }
    fn upgrade_mod(&self, m: &Mod) {
        if self.catalog.is_empty() {
            log::error!("No mod catalog loaded, upgrade impossible.");
            return;
        }
        let m = m.clone();
        let catalog = self.catalog.clone();
        tokio::spawn(async move {
            match catalog.iter().find(|r| is_same_mod(&m, r)) {
                Some(remote) => {
                    info!("Reinstalling {}...", remote.name);
                    let disabled = m.folder.join(".lovelyignore").exists();
                    let target = install_dir(remote);
                    let mods_dir = ModList::get_local_mod_dir();
                    let migrating = m.folder != mods_dir.join(&target);
                    match reinstall_mod(remote, disabled, &target).await {
                        Ok(_) => {
                            if migrating {
                                match std::fs::remove_dir_all(&m.folder) {
                                    Ok(_) => info!(
                                        "Migrated {} to {}",
                                        m.folder.display(),
                                        target
                                    ),
                                    Err(e) => error!(
                                        "Failed to remove old folder {}: {}",
                                        m.folder.display(),
                                        e
                                    ),
                                }
                            }
                            info!("{} reinstalled.", remote.name);
                        }
                        Err(e) => {
                            error!("Failed to reinstall {}: {}", remote.name, e)
                        }
                    }
                }
                None => {
                    info!("{} not in the index, skipping...", m.name);
                }
            }
        });
    }
    fn build_options(&mut self) {
        self.mods.sort_by(|a, b| a.name.cmp(&b.name));

        self.options.options.clear();
        if self.options.selected >= self.mods.len() {
            self.options.selected = self.mods.len().saturating_sub(1);
        }

        self.mods.iter_mut().for_each(|m| {
            self.options.options.push(vec![
                OptionSelectorText::new(m.name.clone(), Style::default()),
                OptionSelectorText::new(
                    format!(" {} ", m.version.clone()),
                    Style::default().fg(Color::LightBlue),
                ),
                OptionSelectorText::new(
                    format!("by {}", m.author.clone().join(", ")),
                    Style::default().fg(Color::DarkGray),
                ),
            ]);
            if !m.enabled.unwrap_or(true) {
                self.options
                    .options
                    .last_mut()
                    .unwrap()
                    .push(OptionSelectorText::new(
                        " (disabled)".to_string(),
                        Style::default().fg(Color::Red),
                    ));
            }
        });
    }
}

impl Component for ModlistComponent {
    fn register_action_handler(&mut self, tx: UnboundedSender<Action>) -> Result<()> {
        self.action_tx = Some(tx.clone());
        self.options.register_action_handler(tx.clone())?;
        self.options
            .register_local_action_handler(self.local_action_tx.clone())?;
        Ok(())
    }
    fn handle_key_event(&mut self, key: KeyEvent) -> Result<Option<Action>> {
        match key.code {
            KeyCode::Char(c)
                if (c == 'u' || c == 'U') && key.modifiers.contains(KeyModifiers::SHIFT) =>
            {
                if let Some(tx) = self.action_tx.as_ref() {
                    tx.send(Action::ReinstallMods)?;
                }
            }
            KeyCode::Char('u') => {
                if let Some(m) = self.mods.get(self.options.selected) {
                    self.upgrade_mod(m);
                }
            }
            _ => {
                self.options.handle_key_event(key)?;
            }
        }
        Ok(None)
    }

    fn update(&mut self, action: Action) -> Result<Option<Action>> {
        if action == Action::Tick {
            let act = self.local_action_rx.try_recv();
            if act.is_ok() {
                let a = act?;
                match a {
                    Actions::Selected(c) => {
                        let m = &mut self.mods[c];
                        m.toggle_enabled();
                        self.build_options();
                    }
                    Actions::Delete(c) => {
                        let m = &self.mods[c];
                        if m.force_enable {
                            log::error!(
                                "This mod is marked as force enabled and cannot be deleted!"
                            );
                        } else {
                            match std::fs::remove_dir_all(&m.folder) {
                                Ok(_) => {
                                    log::info!("Deleted {} at {}", m.name, m.folder.display());
                                    self.mods = ModList::get_local_mods();
                                    self.build_options();
                                }
                                Err(e) => {
                                    log::error!(
                                        "Failed to delete {} at {}: {}",
                                        m.name,
                                        m.folder.display(),
                                        e
                                    );
                                }
                            }
                        }
                    }
                    Actions::Reload => {
                        self.mods = ModList::get_local_mods();
                        self.build_options();

                        // remove any other reload requests from action queue
                        while let Ok(a) = self.local_action_rx.try_recv() {
                            if let Actions::Reload = a {
                            } else {
                                let _ = self.local_action_tx.send(a);
                            }
                        }
                    }
                }
            }
        }
        Ok(None)
    }

    fn draw(&mut self, frame: &mut Frame, area: Rect) -> Result<()> {
        let (about_len, main_len) = (60, 60);
        let [about_area, right_area] =
            Layout::horizontal([Constraint::Length(about_len), Constraint::Length(main_len)])
                .flex(Flex::SpaceEvenly)
                .areas(area);
        let mut about = About::new();
        about.draw(frame, about_area)?;
        self.options
            .draw(
                frame,
                right_area.inner(Margin {
                    horizontal: 1,
                    vertical: 1,
                }),
            )
            .expect("Options failed to draw!");
        Ok(())
    }

    fn focus(&mut self) {
        self.has_focus = true;
        self.options.focus();
    }

    fn unfocus(&mut self) {
        self.has_focus = false;
        self.options.unfocus();
    }
}
