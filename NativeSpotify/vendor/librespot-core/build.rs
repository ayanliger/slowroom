use rand::Rng;
use rand_distr::Alphanumeric;
use vergen_gitcl::{BuildBuilder, Emitter};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("cargo:rustc-env=VERGEN_GIT_SHA=99b6088");
    println!("cargo:rustc-env=VERGEN_GIT_COMMIT_DATE=2026-10-21");

    let build = BuildBuilder::default()
        .build_date(true) // outputs 'VERGEN_BUILD_DATE'
        .build()?;

    Emitter::default()
        .add_instructions(&build)?
        .emit()
        .expect("Unable to generate the cargo keys!");
    let build_id = match std::env::var("SOURCE_DATE_EPOCH") {
        Ok(val) => val,
        Err(_) => rand::rng()
            .sample_iter(Alphanumeric)
            .take(8)
            .map(char::from)
            .collect(),
    };

    println!("cargo:rustc-env=LIBRESPOT_BUILD_ID={build_id}");
    Ok(())
}
