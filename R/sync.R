GithubGists <- R6::R6Class(
  "GithubGists",
  public = list(
    user = NULL,
    complete = FALSE,
    initialize = function(user = NULL) {
      requires_pkg("gh")
      self$user <- if (is.null(user)) {
        gh::gh_whoami()$login
      } else user

      first_page <- gh::gh("/users/:user/gists", user = self$user, per_page = 10)
      private$is_complete(first_page)
      private$pages <- list(first_page)
    },
    next_page = function() {
      next_page <- gh::gh_next(private$pages[[length(private$pages)]])
      private$is_complete(next_page)
      private$pages <- c(private$pages, list(next_page))
      self$view(length(private$pages))
    },
    n_pages = function() {
      length(private$pages)
    },
    gist = function(id) {
      stopifnot(is.character(id), length(id) == 1)
      for (page in private$pages) {
        for (gist in page) {
          if (gist$id == id) return(gist)
        }
      }
      stop("Gist not found: ", id)
    },
    view = function(page = NULL, raw = FALSE) {
      if (is.null(page)) {
        pages <- lapply(seq_along(private$pages), self$view, raw = raw)
        out <- list()
        for (item in pages) {
          out <- c(out, item)
        }
        return(out)
      }

      if (page < 1) return(NULL)

      if (page > length(private$pages)) {
        if (!self$complete) {
          return(self$next_page())
        } else {
          return(NULL)
        }
      }

      gists <- private$pages[[page]]
      if (raw) return(gists)

      lapply(gists, function(g) {
        c(
          g[c("id", "html_url", "public", "created_at", "updated_at", "description")],
          list(files = paste(names(g$files), collapse = ", "))
        )
      })
    },
    df = function(page = NULL, icon_link = TRUE) {
      x <- self$view(page)
      x <- lapply(x, function(g) {
        g$public <- ifelse(g$public, "Public", "Private")
        if (icon_link) {
          g$html_url <- paste0(
            '<a href="', g$html_url, '"><svg xmlns="http://www.w3.org/2000/svg" ',
            'width="16" height="16" viewBox="0 0 24 24" fill="none"',
            'stroke="currentColor" stroke-width="2" stroke-linecap="round"',
            'stroke-linejoin="round" class="feather feather-external-link">',
            '<path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"></path>',
            '<polyline points="15 3 21 3 21 9"></polyline>',
            '<line x1="10" y1="14" x2="21" y2="3"></line></svg></a>'
          )
        }
        g$updated_at <- sub("([\\d-]{10})T([\\d:]{5}).+", "\\1 \\2", g$updated_at, perl = TRUE)
        g$created_at <- sub("([\\d-]{10})T([\\d:]{5}).+", "\\1 \\2", g$created_at, perl = TRUE)
        g
      })
      if (length(x) == 1) {
        as.data.frame(x)
      } else {
        as.data.frame(do.call("rbind", x))
      }
    }
  ),
  private = list(
    pages = list(),
    is_complete = function(res) {
      link <- attributes(res)$response$link
      has_next <- !is.null(link) && grepl('rel="next"', link, fixed = TRUE)
      self$complete <- !has_next
      !has_next
    }
  )
)


gistfo_app <- function(user = NULL, preload_all_gists = FALSE) {
  requires_pkg("gh")
  requires_pkg("shiny")
  requires_pkg("miniUI")
  requires_pkg("reactable")

  if (is.null(user)) user <- getOption("github.username", NULL) # ?gistr::gists
  gh_user <- gh::gh_whoami()
  user_has_gist_scope <- if (!is.null(gh_user)) {
    any(grepl("gist", gh_user$scopes))
  } else {
    FALSE
  }
  if (is.null(user)) {
    user <- gh_user$login
    if (!user_has_gist_scope) {
      warning(
        "You do not have the 'gist' scope enabled for your GitHub PAT for user ",
        '"', user, '". See ?gh::gh_whoami for more information on how to set ',
        "up your GitHub PAT and be sure to include at least the gist and user ",
        "scopes for {gistfo} to work properly.",
        call. = FALSE,
        immediate. = TRUE
      )
    }
  }

  if (is.null(user) || !nzchar(user)) {
    stop(
      "Couldn't guess user name. Please set your GitHub user name via ",
      "`options(\"github.username\" = \"ghuser\")` or set up a GitHub PAT ",
      "(see ?gh::gh_whoami for more information). Finally, you can manually call ",
      'the app with your username: `gistfo:::gistfo_app("ghuser")`.'
    )
  }

  gists <- GithubGists$new(user = user)
  if (!gists$complete) gists$next_page()
  if (isTRUE(preload_all_gists)) {
    cat("Loading gists..")
    while(!gists$complete) {
      gists$next_page()
      cat(".")
    }
  }

  owns_gist <- function(id) {
    if (is.null(gh_user$login)) return(FALSE)
    gh_user$login == gists$gist(id)$owner$login
  }

  theme <- gistfo_app_theme()

  ui <- miniUI::miniPage(
    title = "GitHub Gists",
    shiny::tags$style(shiny::HTML(
      sprintf(paste(
        sep = "\n",
        "body, .ReactTable { background-color: %s; color: %s; }",
        ".rt-search { color: %s; }",
        ".gadget-title { background-color: %s; border-bottom: none; }"
      ), theme$background, theme$color, theme$search, theme$title_bar_background)
    )),
    miniUI::miniTitleBar(
      title = "GitHub Gists",
      left = shiny::div(
        shiny::uiOutput("left_buttons")
      ),
      right = shiny::div(
        id = "gist-action-buttons",
        miniUI::miniTitleBarButton("save_gist", "Save Gist"),
        miniUI::miniTitleBarButton("open_gist", "Open Gist", TRUE)
      )
    ),
    miniUI::miniContentPanel(
      reactable::reactableOutput("gists", height = "100%"),
      scrollable = TRUE,
      height = "100%"
    ),
    shiny::tags$script(shiny::HTML(
      "Shiny.addCustomMessageHandler('toggleActions', function(state) {
        const btns = document.querySelectorAll('#gist-action-buttons button');
        for (let i = 0; i < btns.length; i++) {
          btns[i].classList.toggle('disabled', !state);
          state ? btns[i].removeAttribute('disabled') : btns[i].setAttribute('disabled', true);
        }
      });"
    ))
  )

  server <- function(input, output, session) {
    trigger_table_update <- shiny::reactiveVal(NULL)

    if (user_has_gist_scope) {
      # if the user has the gist scope, then they can write gists back to their account
      # and we check each gist to make sure they're the owner (idk, maybe forks?)
      # then we poll RStudio for the currently open tab and if it's a gist
      # that the app opened, we return the gist id grabbed from the temp dir
      # where the gist is stored. Finally, we use a dynamic html output to
      # update the buttons on the left side of the app: "Update gist-file.R"
      rstudio_open_gist_file <- shiny::reactivePoll(
        1000, session,
        checkFunc = function() {
          rstudioapi::getSourceEditorContext()$path
        },
        valueFunc = function() {
          open_tab <- rstudioapi::getSourceEditorContext()$path
          if (is.null(open_tab) || open_tab == "") return(NULL)
          id <- basename(dirname(open_tab))
          ids <- sapply(gists$view(), function(x) x$id)
          if (id %in% ids) {
            if (!owns_gist(id)) return(NULL)
            basename(open_tab)
          }
        }
      )

      output$left_buttons <- shiny::renderUI({
        if (shiny::isTruthy(rstudio_open_gist_file())) {
          filename <- rstudio_open_gist_file()
          if (nchar(filename) > 16) {
            filename <- paste0(substr(filename, 1, 16), "...")
          }
          shiny::tagList(
            miniUI::miniTitleBarCancelButton(label = "Quit"),
            miniUI::miniTitleBarButton(
              "update_gist",
              shiny::HTML(
                paste0("Update <code>", filename, "</code>")
              )
            ),
          )
        } else {
          miniUI::miniTitleBarCancelButton(label = "Quit")
        }
      })
    } else {
      # User doesn't have "gist" scope, so can only quit (or open gists)
      output$left_buttons <- shiny::renderUI({
        miniUI::miniTitleBarCancelButton(label = "Quit")
      })
    }

    output$gists <- reactable::renderReactable({
      tbl <- gists$df()[, c("description", "files", "created_at", "updated_at", "public", "html_url")]
      names(tbl) <- c("Description", "Files", "Created", "Updated", "Public", "Link")
      reactable::reactable(
        tbl,
        selection = "single",
        onClick = "select",
        borderless = TRUE,
        searchable = TRUE,
        pagination = TRUE,
        paginationType = "numbers",
        theme = reactable::reactableTheme(
          rowSelectedStyle = list(
            backgroundColor = theme$highlight_background,
            boxShadow = "inset 2px 0 0 0 #337ab7"
          ),
          rowStyle = list(verticalAlign = "middle")
        ),
        columns = list(
          Description = reactable::colDef(minWidth = 125),
          Files = reactable::colDef(minWidth = 125),
          Created = reactable::colDef(minWidth = 80, cell = vague_time_since),
          Updated = reactable::colDef(minWidth = 80, cell = vague_time_since),
          Link = reactable::colDef(minWidth = 50, html = TRUE, align = "center", sortable = FALSE),
          Public = reactable::colDef(
            minWidth = 60,
            cell = function(value) if (value == "Public") "" else "\U1F512",
            align = "center"
          )
        )
      )
    })

    shiny::observeEvent(trigger_table_update(), {
      tbl <- gists$df()[, c("description", "files", "created_at", "updated_at", "public", "html_url")]
      names(tbl) <- c("Description", "Files", "Created", "Updated", "Public", "Link")
      reactable::updateReactable("gists", data = tbl, page = reactable::getReactableState("gists", "page"))
    })

    gists_selected <- shiny::reactive({
      sel_id <- reactable::getReactableState("gists")$selected
      shiny::req(sel_id)
      gists$df()[, "id"][[sel_id]]
    })

    shiny::observe({
      has_sel <- !is.null(reactable::getReactableState("gists")$selected)
      session$sendCustomMessage('toggleActions', has_sel)
    })

    shiny::observeEvent(reactable::getReactableState("gists"), {
      state <- reactable::getReactableState("gists")
      shiny::req(state)
      if (state$page != 1 && state$page == state$pages && !gists$complete) {
        gists$next_page()
        trigger_table_update(Sys.time())
      }
    })

    shiny::observeEvent(input$cancel, shiny::stopApp())
    shiny::observeEvent(input$open_gist, gist_open_rstudio(gists_selected()))
    shiny::observeEvent(input$save_gist, gist_open_rstudio(gists_selected(), NULL, NULL))
    shiny::observeEvent(input$update_gist, update_gist())
  }

  shiny::runGadget(ui, server, viewer = shiny::paneViewer(400))
}

gist_open_rstudio <- function(id, dir = tempdir(), open = TRUE) {
  if (is.null(dir)) {
    dir <- rstudioapi::selectDirectory(label = "Choose a parent directory for the gist")
  }
  if (is.null(dir)) {
    message("Cancelled by user")
    return(NULL)
  }
  if (is.null(open)) {
    open <- rstudioapi::showQuestion("Open Gist Files", "Do you want to open the gist files?", "Yes", "No")
  }
  g <- gistr::gist_save(id, dir)
  files <- list.files(file.path(dir, id), full.names = TRUE, all.files = TRUE)
  files <- files[!grepl("/[.]{1,2}$", files)]
  lapply(files, rstudioapi::navigateToFile)
  invisible(id)
}

update_gist <- function(path = NULL, id = NULL) {
  if (is.null(path)) {
    path <- rstudioapi::getSourceEditorContext()$path
    path <- dirname(path)
  }
  if (!dir.exists(path)) {
    stop("`path` should be a directory containing a gist")
  }
  if (is.null(id)) {
    id <- basename(path)
  }
  g <- gistr::gist(id)
  g$update_files <- as.list(list.files(
    path, full.names = TRUE, all.files = TRUE, no.. = TRUE, include.dirs = FALSE
  ))
  g <- gistr::update(g)
  message("Updated gist ", id)
  invisible(g)
}

vague_time_since <- function(value) {
  if (!requireNamespace("prettyunits", quietly = TRUE)) {
    return(value)
  }
  prettyunits::vague_dt(
    difftime(Sys.time(), strptime(value, "%F %H:%M"))
  )
}

gistfo_app_theme <- function() {
  theme <- list(
    background = "#FFFFFF",
    color = "#333333",
    search = "#333333",
    highlight_background = "#eeeeee",
    title_bar_background = "#e5e5e5",
    dark = FALSE
  )

  if (!rstudioapi::hasFun("getThemeInfo")) return(theme)

  rstheme <- rstudioapi::getThemeInfo()

  theme$dark <- rstheme$dark
  if (is.null(rstheme$foreground)) return(theme)

  theme$background <- rstheme$background
  theme$color <- rstheme$foreground
  theme$search <- if (theme$dark) rstheme$background else rstheme$foreground
  theme$highlight_background <- alpha_rgb(rstheme$foreground, 0.05)
  theme$title_bar_background <- alpha_rgb(rstheme$foreground, 0.10)

  theme
}

alpha_rgb <- function(x, alpha = 0.5) {
  if (grepl("^rgb", x)) {
    x <- sub(
      "rgb\\((\\d+, ?\\d+, ?\\d+)\\)",
      sprintf("rgba(\\1, %s)", alpha),
      x
    )
  }
  x
}
